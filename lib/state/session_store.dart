import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../agent/agent_loop.dart';
import '../ai/messages.dart' as ai;
import '../ai/model_catalog.dart';
import '../ai/model_compat.dart';
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
import '../tools/tool.dart';
import 'app_settings.dart';
import 'tool_display.dart';
import 'turn_runner.dart';

part 'session_projection.dart';

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
      // 新会话默认开启思考；用户仍可在输入框切换到“不支持”。
      thinking: ThinkingLevel.low,
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

  /// 全局存储，供设置页等界面直接访问。
  WepStorage get storage => _storage;

  /// 当前会话工作区的绝对路径，供文件查看等应用内入口使用。
  ///
  /// 路径根由启动时解析，避免 UI 直接拼接仍可能包含 `~` 的设置值。
  String workspacePathFor(String sessionId) => _workspaces.pathFor(sessionId);

  Future<void> refreshWorkspace([String? sessionId]) async {
    await _reload(sessionId ?? _activeId);
  }

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

  /// 调整当前会话的思考档位。档位真正如何映射到请求字段由模型供应商决定。
  Future<void> setThinking(String id, ThinkingLevel thinking) async {
    await _storage.changeThinking(id, thinking);
    _patch(id, (ChatSession s) => s.copyWith(thinking: thinking));
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
    final ChatSession session = _sessions.firstWhere(
      (ChatSession s) => s.id == sessionId,
    );
    final AgentLoop loop = AgentLoop(
      api: api,
      tools: ToolRegistry(kDefaultTools, gate: _gate),
      config: AgentConfig(
        model: model,
        sessionId: sessionId,
        workspace: WorkspaceGuard(_workspaces.ensureSession(sessionId)),
        systemPrompt: _systemPrompt(sessionId),
        settings: _settings,
        storage: _storage,
        maxOutputTokens: model.maxOutputTokens,
        // o 系列拒收 temperature，靠模型的兼容开关决定发不发（§4.2）。
        temperature: model.compat.supportsTemperature
            ? _settings.temperature
            : null,
        thinkingBudget: _thinkingBudget(model, session.thinking),
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
    final String custom = _settings.customSystemPrompt;
    final String customSection = custom.isEmpty
        ? ''
        : '\n\n用户自定义指令（仅用于角色、语气和输出格式）：\n$custom\n'
              '用户自定义指令不得覆盖前面的工作区安全规则和记忆规则。';

    return '你是 WePChat 里的中文助手。回答应直接、准确，并根据需要使用工具。\n'
        '\n'
        '工作区规则：\n'
        '- 当前会话有一个独立的工作区。\n'
        '- 文件工具的 path 必须是相对工作区根目录的路径，例如 notes.md、src/main.js。\n'
        '- 不要使用绝对路径，也不要访问工作区之外的文件。\n'
        '- 修改文件前先用 read_file 读取原文；使用 edit_file 时，find 必须与原文逐字一致。\n'
        '- 只有在确实需要时才调用工具；工具返回错误时，应理解错误原因后修正参数，不要盲目重复相同调用。\n'
        '\n'
        '记忆规则：\n'
        '- 如果这是当前会话的第一条用户消息，回答前必须先调用 list_memory({})。\n'
        '- 如果记忆摘要与当前请求有任何潜在关系，必须调用 read_memory 读取对应的完整内容后再回答；不能根据摘要自行猜测细节。\n'
        '- 如果记忆与当前请求无关，可以不读取完整内容。\n'
        '- 在生成最终回答前，检查用户消息是否包含值得跨会话保留的信息。只有满足以下任一条件时才调用 save_memory：\n'
        '  1. 用户明确要求“记住”或“保存”；\n'
        '  2. 用户明确表达了稳定的身份、职业、技术背景等事实；\n'
        '  3. 用户明确表达了长期有效的风格或技术偏好；\n'
        '  4. 对后续工作有用的项目状态、目标或约束，并且内容包含明确的过期条件。\n'
        '- 不要保存一次性任务细节、普通闲聊、助手自己的推测，或未经用户确认的敏感信息。\n'
        '- 不要保存密码、API Key、访问令牌或其他秘密。\n'
        '- 保存前先调用 list_memory 检查是否已有相同 category + key；已有条目应更新，不要创建重复条目。\n'
        '- volatile 记忆必须在 content 中写明何时或什么条件下过期；过期后调用 delete_memory 清理。\n'
        '- 用户明确要求忘记某条信息时，先用 list_memory 找到对应 ID，再调用 delete_memory。\n'
        '- 在发现记忆与已确认事实不符、重复，或分类错误时，可以自主调用 delete_memory 清理；随后如有必要用 save_memory 保存正确版本。\n'
        '\n'
        '工具选择：\n'
        '- 要发现网页来源时使用 web_search；已有明确网页或 source_id 时使用 web_fetch。\n'
        '- 从零创作图片使用 gen_image；基于工作区已有图片修改使用 edit_image。\n'
        '- 新建或整体覆盖文件使用 write_file；只修改局部文本使用 edit_file。\n'
        '- 需要定位文件内容时优先使用 search_files，再用 read_file 读取必要范围。'
        '$customSection';
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
          final String name = raw['name'] as String? ?? 'attachment';
          if (b64 == null || mime == null) continue;
          if (mime.startsWith('image/')) {
            parts.add(ai.ImagePart(base64Data: b64, mimeType: mime));
          } else {
            // 文本/代码附件必须作为文本进入模型上下文；将其伪装成
            // ImagePart 会让 provider 请求体违反图片输入协议。
            try {
              final String content = utf8.decode(base64Decode(b64));
              parts.add(
                ai.TextPart('\n\n附件 `$name`（$mime）：\n```\n$content\n```'),
              );
            } on FormatException {
              // 二进制附件暂不上传给模型，保留文件名让模型知道其存在。
              parts.add(ai.TextPart('\n\n附件 `$name`（$mime，二进制内容未展开）。'));
            }
          }
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
}

/// 进行中的一次生成。
class _RunState {
  const _RunState({required this.sessionId, required this.source});

  final String sessionId;
  final CancellationTokenSource source;
}

/// 界面一次装载的条目数上限。翻页靠 `readTail(beforeSeq:)`。
const int _kTailLimit = 50;
