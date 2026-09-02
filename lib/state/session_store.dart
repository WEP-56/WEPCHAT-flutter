import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../agent/agent_loop.dart';
import '../ai/messages.dart' as ai;
import '../ai/model_catalog.dart';
import '../ai/provider_api.dart';
import '../ai/provider_config.dart';
import '../ai/provider_factory.dart';
import '../core/cancellation_token.dart';
import '../core/errors.dart';
import '../core/ulid.dart';
import '../models/chat.dart';
import '../models/content.dart';
import '../models/markdown_blocks.dart';
import '../models/tool_call.dart';
import '../models/workspace.dart';
import '../platform/workspace_guard.dart';
import '../platform/workspace_paths.dart';
import '../platform/workspace_scanner.dart';
import '../storage/storage.dart';
import '../tools/permission_gate.dart';
import '../tools/tool_registry.dart';
import '../tools/tool_summary.dart';
import 'app_settings.dart';
import 'tool_display.dart';
import 'turn_runner.dart';

/// 会话列表与当前会话的可变状态，背后是真存储（实施 TODO §9-12、M1、M2）。
///
/// 构造前必须先 [load]：会话列表在首帧之前就绪，界面不需要处理"加载中"
/// 状态，也就不需要为接存储改一行 UI 代码。
///
/// M2 起 [sendMessage] 走 `AgentLoop`：模型可以调工具，工具经权限门，
/// 结果每个执行完立刻落库。M1 那条"直接消费 `api.stream`"的捷径已经拆掉
/// ——两条链路并存的话，工具、权限、迭代上限这些规矩就得在两处各写一遍。
class SessionStore extends ChangeNotifier {
  SessionStore._({
    required WepStorage storage,
    required WorkspaceRoots workspaces,
    required AppSettings settings,
    required List<ChatSession> sessions,
    required String activeId,
    required PermissionGate gate,
  }) : _storage = storage,
       _workspaces = workspaces,
       _settings = settings,
       _sessions = sessions,
       _activeId = activeId,
       _gate = gate;

  /// 打开存储里的会话列表，必要时补一个空会话。
  ///
  /// 默认模型取自 [settings]，可能为 null——用户还没配任何 provider 时就是
  /// 这种状态，会话照样能建，点发送时才提示。
  ///
  /// [permissionPrompt] 是「询问」档位的弹窗入口，由界面在 `main` 里接上。
  /// 不传就没有确认界面，`ask` 一律按拒绝处理（见 `PermissionGate`）——
  /// headless 测试就是这种情况。
  static Future<SessionStore> load({
    required WepStorage storage,
    required WorkspaceRoots workspaces,
    required AppSettings settings,
    PermissionPrompt? permissionPrompt,
  }) async {
    final List<ChatSession> sessions = await _loadAll(storage, workspaces);

    if (sessions.isEmpty) {
      // 空库首启：建一个会话，保证 [active] 始终有值（界面依赖这条不变量）。
      sessions.add(
        _toChatSession(
          await _createRecord(
            storage,
            workspaces,
            settings.defaultModel?.key ?? '',
          ),
          const <EntryRecord>[],
        ),
      );
    }

    return SessionStore._(
      storage: storage,
      workspaces: workspaces,
      settings: settings,
      sessions: sessions,
      activeId: sessions.first.id,
      gate: PermissionGate(settings: settings, prompt: permissionPrompt),
    );
  }

  /// 建会话记录并落盘工作区目录。
  ///
  /// 目录名要用 `session_id`，而 id 是 `createSession` 里生成的，所以只能
  /// 先建记录、拿到 id、再建目录、最后把路径写回记录（§7-1）。
  static Future<SessionRecord> _createRecord(
    WepStorage storage,
    WorkspaceRoots workspaces,
    String model,
  ) async {
    final SessionRecord record = await storage.createSession(
      title: '新会话',
      workspaceRoot: workspaces.root,
      providerId: _providerFor(model),
      modelId: model,
    );
    workspaces.ensureSession(record.id);
    return record;
  }

  final WepStorage _storage;
  final WorkspaceRoots _workspaces;
  final AppSettings _settings;
  final PermissionGate _gate;
  List<ChatSession> _sessions;
  String _activeId;

  /// 进行中的生成任务。全局只允许一个。
  ///
  /// 这是个刻意的简化：日常聊天客户端同时发两个请求的场景基本不存在，
  /// 而支持并发要给每个会话各存一份取消源、各管一条流，收益对不上复杂度。
  _RunState? _run;

  /// 一次性提示文本，界面取走后就没了。
  ///
  /// 配置类失败（没配 key、没有模型）走这里而不是落库：它们不是对话内容，
  /// 写进历史会永远留在记录里，用户改完设置也擦不掉。
  String? _notice;

  /// 上次退出时正在生成、没能正常结束的会话（实施 TODO §10-6、§9-7）。
  ///
  /// 由 `AppBootstrap` 在启动时扫出来交进来。只做提示不自动重发（§13.5 已定）：
  /// 用户可能就是故意杀掉的，替他重发一次要花钱。
  final Set<String> _interrupted = <String>{};

  bool get activeWasInterrupted => _interrupted.contains(_activeId);

  void markInterrupted(Iterable<String> sessionIds) {
    _interrupted
      ..clear()
      ..addAll(sessionIds);
    notifyListeners();
  }

  /// 用户看过提示了，或者已经重新发过消息。
  void clearInterrupted(String sessionId) {
    if (_interrupted.remove(sessionId)) notifyListeners();
  }

  List<ChatSession> get sessions => List<ChatSession>.unmodifiable(_sessions);
  String get activeId => _activeId;

  /// 当前会话有请求在跑。界面据此显示停止按钮、禁用发送。
  ///
  /// 看的是**当前**会话而不是"有没有任务"：生成中切到别的会话，那边的输入框
  /// 应该是能用的样子，显示一个停不掉自己的停止按钮只会让人困惑。
  bool get isGenerating => _run?.sessionId == _activeId;

  /// 某个会话是否在生成。会话列表用它显示小圆点。
  bool isGeneratingIn(String sessionId) => _run?.sessionId == sessionId;

  /// 取走待显示的提示，同时清空。界面在 listener 里调，显示成 toast。
  String? takeNotice() {
    final String? notice = _notice;
    _notice = null;
    return notice;
  }

  ChatSession get active {
    return _sessions.firstWhere((ChatSession s) => s.id == _activeId);
  }

  void select(String id) {
    if (_activeId == id) return;
    if (_sessions.every((ChatSession s) => s.id != id)) {
      throw ArgumentError.value(id, 'id', '会话不存在');
    }
    _activeId = id;
    notifyListeners();
  }

  /// 新建空会话并切换过去。[model] 是 `ModelSpec.key`。
  Future<ChatSession> createSession({required String model}) async {
    final SessionRecord record = await _createRecord(
      _storage,
      _workspaces,
      model,
    );
    final ChatSession session = _toChatSession(record, const <EntryRecord>[]);
    _sessions = <ChatSession>[session, ..._sessions];
    _activeId = session.id;
    notifyListeners();
    return session;
  }

  /// 删除会话；删掉最后一个时补一个空会话，保证 [active] 始终有值。
  Future<void> deleteSession(String id, {required String fallbackModel}) async {
    if (_sessions.every((ChatSession s) => s.id != id)) {
      throw ArgumentError.value(id, 'id', '会话不存在');
    }
    await _storage.deleteSession(id);
    // 「本会话内一直允许」跟着会话走。不清的话，id 万一被复用，
    // 新会话会凭空继承一份授权。
    _gate.forgetSession(id);
    _sessions = _sessions.where((ChatSession s) => s.id != id).toList();

    if (_sessions.isEmpty) {
      await createSession(model: fallbackModel);
      return;
    }
    if (id == _activeId) _activeId = _sessions.first.id;
    notifyListeners();
  }

  Future<void> renameSession(String id, String title) async {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return;
    await _storage.renameSession(id, trimmed);
    _patch(id, (ChatSession s) => s.copyWith(title: trimmed));
  }

  /// 换模型：存储层追加 `model_change` 条目并更新缓存列（存储设计 §7.3）。
  Future<void> setModel(String id, String model) async {
    await _storage.changeModel(
      id,
      providerId: _providerFor(model),
      modelId: model,
    );
    _patch(id, (ChatSession s) => s.copyWith(model: model));
  }

  /// 发一条新消息：落库 + 请模型回复。
  Future<void> sendMessage(
    String text, {
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;
    if (_run != null) return; // 同时只跑一个。

    final ChatSession session = active;
    await _askWithUserMessage(
      session,
      trimmed,
      attachments: attachments,
      isFirst: session.messages.isEmpty,
    );
  }

  /// 重发：撤回这条消息之后的历史，让模型重新回答（存储设计 §8）。
  ///
  /// - 传**用户消息**：留着它本身，撤回它之后的一切，用同一句话再问一次。
  /// - 传**助手消息**：连它一起撤回，这一轮重新回答。
  ///
  /// 撤回不删条目，只追加一条 `truncate` 标记；被撤回的区间从上下文和界面上
  /// 一起消失。传**助手消息**时那一轮的工具结果留着：它们的 seq 比助手消息
  /// 小，落在撤回区间之外，而副作用真的发生过（存储设计 §6.1），界面上留着
  /// 那几张卡片是诚实的。
  Future<void> regenerate(ChatMessage message) async {
    if (_run != null) return;
    // seq 为 0 的是流式草稿或工具卡片，没有落库位置可撤。
    if (message.seq <= 0) return;

    final ChatSession session = active;
    clearInterrupted(session.id);

    await _storage.truncateFrom(
      session.id,
      fromSeq: message.isUser ? message.seq + 1 : message.seq,
    );
    await _reload(session.id);
    await _generate(session.id, session.model);
  }

  /// 改掉一条用户消息重发（存储设计 §8，实施 TODO §9-10）。
  ///
  /// 从这条消息起整段撤回，再追加改过的新消息——不是就地改那条条目：
  /// 条目写入即不可变（存储设计 §7.1）。
  Future<void> editUserMessage(ChatMessage message, String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_run != null) return;
    if (!message.isUser || message.seq <= 0) return;

    final ChatSession session = active;
    // 改的是第一句话，标题跟着改：标题本来就是从它取的（功能协议 §2.1）。
    final bool isFirst =
        session.messages.isNotEmpty && session.messages.first.id == message.id;

    await _storage.truncateFrom(session.id, fromSeq: message.seq);
    await _askWithUserMessage(session, trimmed, isFirst: isFirst);
  }

  /// 落一条用户消息，然后请模型回复。
  ///
  /// 用户消息**先落库**再考虑能不能发请求：没配 key 的时候把用户刚打的字
  /// 丢掉是最糟的处理方式，输入框那边已经清空了。
  ///
  /// [isFirst] 时顺带把标题从"新会话"改成用户第一句话（功能协议 §2.1）。
  Future<void> _askWithUserMessage(
    ChatSession session,
    String text, {
    required bool isFirst,
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) async {
    // 用户又发话了，"上次被中断"这条提示就过期了。
    clearInterrupted(session.id);

    await _storage.appendEntry(
      session.id,
      NewEntry(
        id: Ulid.generate(),
        type: EntryType.message,
        role: EntryRole.user,
        payload: <String, Object?>{
          'text': text,
          if (attachments.isNotEmpty)
            'attachments': <Map<String, Object?>>[
              for (final PendingAttachment a in attachments)
                <String, Object?>{
                  'name': a.name,
                  'mimeType': a.mimeType,
                  'base64': base64Encode(a.bytes),
                },
            ],
        },
      ),
      preview: text,
    );

    if (isFirst) {
      await _storage.renameSession(session.id, _titleFrom(text));
    }

    await _reload(session.id);
    await _generate(session.id, session.model);
  }

  /// 中断进行中的请求。已经吐出来的文字会以 `aborted` 落库。
  ///
  /// 只停当前会话的：停止按钮长在当前会话的输入框上，按它去停别处的任务
  /// 不是用户的意思。
  void stopGenerating() {
    final _RunState? run = _run;
    if (run == null || run.sessionId != _activeId) return;
    run.source.cancel();
  }

  // ───────────────────────── 生成 ─────────────────────────

  /// 解析模型与 provider，跑一轮 agent 循环。
  ///
  /// 配置类失败（模型没了、provider 没了、没配 key）只发 [_notice]，不落库。
  Future<void> _generate(String sessionId, String modelKey) async {
    ModelSpec? model = _settings.modelByKey(modelKey);

    if (model == null) {
      // 会话指着一个已删除的模型。用默认模型顶上，只作用于这一次请求——
      // 不写 `model_change`，用户可能只是想临时发一句，不该改动会话记录。
      model = _settings.defaultModel;
      if (model == null) {
        _fail('还没有可用的模型，先去设置页添加');
        return;
      }
      _notice = '「$modelKey」已不在模型列表里，这次用 ${model.displayName} 发送';
    }

    final ProviderConfig? config = _settings.providerOf(model.providerId);
    if (config == null) {
      _fail('模型 ${model.displayName} 的提供商已被删除');
      return;
    }

    final ProviderApi api;
    try {
      api = createProviderApi(model: model, config: config);
    } on WepError catch (e) {
      // 主要是 AuthError：没配 key。这是设置问题，不是对话内容。
      _fail(e.message);
      return;
    }

    final List<ai.ChatMessageModel> history = await _readHistory(sessionId);
    final String runId = await _storage.startRun(sessionId);
    final CancellationTokenSource source = CancellationTokenSource();
    _run = _RunState(sessionId: sessionId, source: source);
    notifyListeners();

    try {
      await _runTurn(
        api: api,
        model: model,
        sessionId: sessionId,
        history: history,
        runId: runId,
        token: source.token,
      );
    } finally {
      _run = null;
      notifyListeners();
    }
  }

  /// 建 loop、跑一轮、收场。
  Future<void> _runTurn({
    required ProviderApi api,
    required ModelSpec model,
    required String sessionId,
    required List<ai.ChatMessageModel> history,
    required String runId,
    required CancellationToken token,
  }) async {
    final AgentLoop loop = AgentLoop(
      api: api,
      tools: ToolRegistry(kDefaultTools, gate: _gate),
      config: AgentConfig(
        model: model,
        sessionId: sessionId,
        workspace: WorkspaceGuard(_workspaces.ensureSession(sessionId)),
        systemPrompt: _systemPrompt(sessionId),
        settings: _settings,
        maxOutputTokens: model.maxOutputTokens,
        // o 系列拒收 temperature，靠模型的兼容开关决定发不发（§4.2）。
        temperature: model.compat.supportsTemperature
            ? _settings.temperature
            : null,
      ),
    );

    final TurnRunner runner = TurnRunner(
      storage: _storage,
      sessionId: sessionId,
      paint: (TurnDraft draft) => _paintDraft(sessionId, draft),
    );

    final TurnResult result;
    try {
      result = await runner.run(loop, history, token);
    } on Object catch (e) {
      // loop 承诺不抛（§5），这里只是兜底：真抛了也不能让 run 悬着。
      _notice = '生成失败：$e';
      await _storage.finishRun(runId, RunOutcome.error);
      await _reload(sessionId);
      return;
    }

    if (result.notice != null) _notice = result.notice;
    await _storage.finishRun(runId, result.outcome);
    await _reload(sessionId);
  }

  /// 本轮的 system prompt。
  ///
  /// 告诉模型工作区在哪、路径怎么写。不写绝对路径：那里面有用户名和真实
  /// 目录结构，不该进模型上下文（AGENTS.md §5.1）；工具收的本来也是相对
  /// 路径。
  String _systemPrompt(String sessionId) {
    return '你是 WePChat 里的助手，用中文回答。\n'
        '你有一个属于当前会话的工作区，文件工具的 path 参数一律用相对'
        '工作区根的相对路径（如 `notes.md`、`src/main.js`），不要用绝对路径，'
        '也不能访问工作区外的任何位置。\n'
        '改文件之前先 read_file 看清原文；edit_file 的 find 必须逐字一致。';
  }

  /// 把存储里的历史条目翻成请求用的消息列表。
  ///
  /// 从 `base_seq` 起读（压缩之后只发摘要以后的部分），跳过被 `truncate`
  /// 标记撤回的区间（编辑重发，存储设计 §8），并丢掉 error / aborted 的
  /// 轮次——半句话和没有结果的调用留在上下文里只会误导模型（§6-14）。
  ///
  /// **工具结果不回放**。落库是为了崩溃恢复和界面显示（存储设计 §6.1），
  /// 但要把它们放回请求里，得连同产生它们的那条 assistant 消息的
  /// `tool_use` 块一起放回去——缺一个配对，API 直接拒（§5-6）。而
  /// `tool_use` 的原始块现在没有落库。这一条留给 M3：那时要做缓存前缀，
  /// 本来就得把 assistant 的 parts 完整存下来。
  Future<List<ai.ChatMessageModel>> _readHistory(String sessionId) async {
    final List<EntryRecord> entries = applyTruncations(
      await _storage.readContext(sessionId),
    );
    final List<ai.ChatMessageModel> history = <ai.ChatMessageModel>[];

    for (final EntryRecord entry in entries) {
      if (entry.type != EntryType.message) continue;
      if (!entry.isUsableInContext) continue;

      final String text = entry.payload['text'] as String? ?? '';
      final List<ai.ContentPart> parts = <ai.ContentPart>[ai.TextPart(text)];
      final Object? rawAttachments = entry.payload['attachments'];
      if (rawAttachments is List) {
        for (final Object? raw in rawAttachments) {
          if (raw is! Map<String, Object?>) continue;
          final String? b64 = raw['base64'] as String?;
          final String? mime = raw['mimeType'] as String?;
          if (b64 == null || mime == null) continue;
          parts.add(ai.ImagePart(base64Data: b64, mimeType: mime));
        }
      }
      switch (entry.role) {
        case EntryRole.user:
          if (text.isNotEmpty || parts.length > 1) {
            history.add(
              ai.ChatMessageModel(role: ai.MessageRole.user, parts: parts),
            );
          }
        case EntryRole.assistant:
          // thinking 不回传：跨模型时别人的思考块会被拒（§6-15），而重放
          // 自己的思考也没有收益。正文为空的轮次直接跳过。
          if (text.isEmpty) continue;
          history.add(
            ai.ChatMessageModel(
              role: ai.MessageRole.assistant,
              parts: <ai.ContentPart>[ai.TextPart(text)],
            ),
          );
        case EntryRole.toolResult:
        case null:
          continue;
      }
    }
    return history;
  }

  /// 把当前草稿画到界面上。
  ///
  /// 只改内存里的那一条，不落库——流式过程中每个 delta 都写一次库既慢又
  /// 违反"条目写入即不可变"（存储设计 §7.1）。落库由 `TurnRunner` 按
  /// 各自的时机做。
  void _paintDraft(String sessionId, TurnDraft draft) {
    final int index = _sessions.indexWhere(
      (ChatSession s) => s.id == sessionId,
    );
    if (index < 0) return;

    final ChatSession session = _sessions[index];
    final ChatMessage bubble = ChatMessage(
      id: draft.bubbleId,
      role: ChatRole.assistant,
      time: _timeLabel(DateTime.now()),
      tools: draft.tools,
      rawText: draft.text,
      blocks: _blocksOf(
        text: draft.text,
        thinking: draft.thinking,
        error: null,
      ),
      isStreaming: true,
    );

    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(
        messages: <ChatMessage>[
          for (final ChatMessage m in session.messages)
            if (m.id != draft.bubbleId) m,
          bubble,
        ],
      );
    notifyListeners();
  }

  /// 配置类失败：只提示，不落库、不建 run。
  void _fail(String message) {
    _notice = message;
    notifyListeners();
  }

  // ───────────────────────── 读取 ─────────────────────────

  /// 从存储重读一个会话，替换列表里的那一项。
  Future<void> _reload(String sessionId) async {
    final SessionRecord? record = await _storage.findSession(sessionId);
    if (record == null) return;
    final List<EntryRecord> entries = await _storage.readTail(
      sessionId,
      limit: _kTailLimit,
    );
    final ChatSession updated = _toChatSession(record, entries);

    // 扫描工作区文件并合并到会话里。
    final String workspacePath = _workspaces.pathFor(sessionId);
    final List<WorkspaceFile> files = await scanWorkspaceDirectory(
      workspacePath,
    );
    final ChatSession withFiles = updated.copyWith(files: files);

    final int index = _sessions.indexWhere(
      (ChatSession s) => s.id == sessionId,
    );
    if (index < 0) return;
    _sessions = List<ChatSession>.of(_sessions)..[index] = withFiles;
    notifyListeners();
  }

  /// 本地改一项，不回存储——调用方已经写过库了。
  void _patch(String id, ChatSession Function(ChatSession) update) {
    final int index = _sessions.indexWhere((ChatSession s) => s.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', '会话不存在');
    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = update(_sessions[index]);
    notifyListeners();
  }

  static Future<List<ChatSession>> _loadAll(
    WepStorage storage,
    WorkspaceRoots workspaces,
  ) async {
    final List<SessionSummary> summaries = await storage.listSessions();
    final List<ChatSession> result = <ChatSession>[];

    for (final SessionSummary summary in summaries) {
      final SessionRecord? record = await storage.findSession(summary.id);
      if (record == null) continue; // 列表与详情之间被删了，跳过。
      final List<EntryRecord> entries = await storage.readTail(
        summary.id,
        limit: _kTailLimit,
      );
      final ChatSession session = _toChatSession(record, entries);

      // 加载工作区文件。
      final String workspacePath = workspaces.pathFor(summary.id);
      final List<WorkspaceFile> files = await scanWorkspaceDirectory(
        workspacePath,
      );
      result.add(session.copyWith(files: files));
    }
    return result;
  }

  static ChatSession _toChatSession(
    SessionRecord record,
    List<EntryRecord> entries,
  ) {
    return ChatSession(
      id: record.id,
      title: record.title,
      group: _groupLabel(record.updatedAt),
      time: _timeLabel(record.updatedAt),
      preview: record.preview.isEmpty ? '还没有消息' : record.preview,
      // 存的是 `ModelSpec.key`（`providerId/modelId`）。界面要显示名字时
      // 拿这个键去设置里查，查不到就显示键本身——用户删掉了那个模型，
      // 会话还在，这时显示原始键比显示空白有用。
      model: record.modelId,
      // 文件列表由 _reload 单独加载并合并，这里先留空。
      files: const <WorkspaceFile>[],
      messages: _toChatMessages(entries),
    );
  }

  /// 条目列表 → 气泡列表。
  ///
  /// 先跳过被 `truncate` 标记撤回的区间：撤回过的消息不该还留在屏幕上
  /// （存储设计 §8）。
  ///
  /// 工具结果不占独立气泡，而是挂到**紧邻的下一条助手消息**上：那条消息
  /// 就是模型看完工具结果之后说的话，两者属于同一个动作。没有后继助手
  /// 消息时（模型只调了工具就被中断）自成一条，否则那次调用在界面上就
  /// 凭空消失了。
  static List<ChatMessage> _toChatMessages(List<EntryRecord> entries) {
    final List<ChatMessage> out = <ChatMessage>[];
    final List<ToolCall> pending = <ToolCall>[];

    for (final EntryRecord entry in applyTruncations(entries)) {
      if (entry.type != EntryType.message) continue;

      if (entry.role == EntryRole.toolResult) {
        pending.add(_toToolCall(entry));
        continue;
      }

      final ChatMessage message = _toChatMessage(entry);
      if (pending.isEmpty || entry.role == EntryRole.user) {
        // 用户消息不该带上一轮的工具卡片。把攒着的先单独放出去。
        if (pending.isNotEmpty) {
          out.add(_toolOnlyMessage(pending));
          pending.clear();
        }
        out.add(message);
        continue;
      }

      out.add(message.copyWith(tools: List<ToolCall>.of(pending)));
      pending.clear();
    }

    if (pending.isNotEmpty) out.add(_toolOnlyMessage(pending));
    return out;
  }

  /// 只有工具卡片、没有正文的一条。
  static ChatMessage _toolOnlyMessage(List<ToolCall> tools) {
    return ChatMessage(
      id: tools.first.id,
      role: ChatRole.toolResult,
      time: '',
      tools: List<ToolCall>.of(tools),
    );
  }

  /// 落库的工具结果 → 卡片。
  ///
  /// 和执行时那张卡片走同一套 `toolKindOf` / `toolTitleOf`
  /// （`tool_display.dart`），刷新前后长得一样。
  static ToolCall _toToolCall(EntryRecord entry) {
    final String name = entry.payload['name'] as String? ?? '未知工具';
    final String content = entry.payload['content'] as String? ?? '';
    final String outcome = entry.payload['outcome'] as String? ?? 'ok';
    final Object? rawArgs = entry.payload['arguments'];

    final String firstLine = content.split('\n').first.trim();
    final String prefix = switch (outcome) {
      'failed' => '失败：',
      'cancelled' => '已中断：',
      'denied' => '已拒绝：',
      _ => '',
    };

    return ToolCall(
      id: entry.id,
      kind: toolKindOf(name),
      title: toolTitleOf(name),
      meta: rawArgs is Map<String, Object?>
          ? summarizeToolArguments(rawArgs)
          : null,
      detail:
          '$prefix${firstLine.length <= 120 ? firstLine : '${firstLine.substring(0, 120)}…'}',
      status: outcome == 'ok' ? ToolStatus.done : ToolStatus.failed,
    );
  }

  static ChatMessage _toChatMessage(EntryRecord entry) {
    final bool isUser = entry.role == EntryRole.user;
    final String text = entry.payload['text'] as String? ?? '';
    final int? elapsedMs = entry.payload['elapsedMs'] as int?;
    final List<Attachment> attachments = <Attachment>[];
    final Object? rawAttachments = entry.payload['attachments'];
    if (rawAttachments is List) {
      for (final Object? raw in rawAttachments) {
        if (raw is! Map<String, Object?> || raw['name'] is! String) continue;
        final String name = raw['name'] as String;
        final String mime = raw['mimeType'] as String? ?? '';
        final FileKind kind = mime.startsWith('image/')
            ? FileKind.png
            : FileKind.txt;
        attachments.add(Attachment(name: name, size: '附件', kind: kind));
      }
    }

    return ChatMessage(
      id: entry.id,
      role: isUser ? ChatRole.user : ChatRole.assistant,
      time: _timeLabel(entry.createdAt),
      seq: entry.seq,
      attachments: attachments,
      // 原始文本原样留一份：复制和编辑要的是 Markdown 源码，从 blocks
      // 反推回去是有损的。
      rawText: text,
      usage: isUser ? null : _usageOf(entry),
      elapsed: elapsedMs == null ? null : Duration(milliseconds: elapsedMs),
      // 用户消息不解析 Markdown：用户打的 `-` 开头是破折号，不是列表。
      blocks: isUser
          ? (text.isEmpty
                ? const <ContentBlock>[]
                : <ContentBlock>[ParagraphBlock(text)])
          : _blocksOf(
              text: text,
              thinking: entry.payload['thinking'] as String? ?? '',
              error: entry.payload['error'] as String?,
            ),
    );
  }

  /// 落库的用量 → 操作栏用量。
  ///
  /// 存储层的字段全是 nullable（不是模型响应的条目就全空），展示层不区分
  /// "没有"和"是 0"，一律折成 0。思考 token 没有独立列，在 payload 里
  /// （见 `TurnRunner._persistAssistant`）。
  static MessageUsage? _usageOf(EntryRecord entry) {
    final TokenUsage usage = entry.usage;
    final int reasoning = entry.payload['reasoningTokens'] as int? ?? 0;
    if (usage.isEmpty && reasoning == 0) return null;
    return MessageUsage(
      inputTokens: usage.inputTokens ?? 0,
      outputTokens: usage.outputTokens ?? 0,
      cacheReadTokens: usage.cacheReadTokens ?? 0,
      cacheWriteTokens: usage.cacheWriteTokens ?? 0,
      reasoningTokens: reasoning,
    );
  }

  /// 助手消息的块结构。流式和落库后走同一个函数，两边长得一样。
  static List<ContentBlock> _blocksOf({
    required String text,
    required String thinking,
    required String? error,
  }) {
    return <ContentBlock>[
      if (thinking.isNotEmpty) QuoteBlock('💭 $thinking'),
      ...parseMarkdownBlocks(text),
      if (error != null && error.isNotEmpty) QuoteBlock('⚠️ $error'),
    ];
  }

  /// 模型键 → provider id。
  ///
  /// 键的形式是 `providerId/modelId`（见 `ModelSpec.key`）。模型 id 自己可能
  /// 带斜杠（`meta/llama-3.1-70b` 这类），所以按**第一个**斜杠切。
  static String _providerFor(String modelKey) {
    final int slash = modelKey.indexOf('/');
    return slash <= 0 ? '' : modelKey.substring(0, slash);
  }

  /// 会话标题取用户第一句话的前几个字（功能协议 §2.1）。
  static String _titleFrom(String text) {
    final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
  }

  /// 侧栏分组标签。
  static String _groupLabel(DateTime updatedAt) {
    final DateTime now = DateTime.now();
    final int days = DateTime(now.year, now.month, now.day)
        .difference(DateTime(updatedAt.year, updatedAt.month, updatedAt.day))
        .inDays;
    if (days <= 0) return '今天';
    if (days == 1) return '昨天';
    if (days < 7) return '过去 7 天';
    if (days < 30) return '过去 30 天';
    return '更早';
  }

  static String _timeLabel(DateTime dt) {
    final String hh = dt.hour.toString().padLeft(2, '0');
    final String mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

/// 进行中的一次生成。
class _RunState {
  const _RunState({required this.sessionId, required this.source});

  final String sessionId;
  final CancellationTokenSource source;
}

/// 界面一次装载的条目数上限。翻页靠 `readTail(beforeSeq:)`。
const int _kTailLimit = 50;
