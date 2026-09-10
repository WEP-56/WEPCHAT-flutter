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
import '../mcp/mcp_connection.dart';
import '../mcp/mcp_session.dart';
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
import '../tools/mcp_tool.dart';
import 'app_settings.dart';
import 'mcp_controller.dart';
import 'tool_display.dart';
import 'turn_runner.dart';

part 'session_projection.dart';
part 'session_generation.dart';

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
    required this.mcp,
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
    McpController? mcp,
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
      mcp: mcp ?? McpController(settings: settings),
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
  final McpController mcp;
  bool _disposed = false;
  Future<void>? _shutdown;
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

    // 删除生成中的会话前先停掉运行，避免流式回调在数据库删除后继续写入。
    final _RunState? run = _run;
    if (run?.sessionId == id) {
      run!.source.cancel();
      await run.done.future;
    }

    final SessionRecord? record = await _storage.findSession(id);
    if (record == null) {
      throw StorageError(
        '删除会话失败：存储中找不到会话',
        context: <String, Object?>{'sessionId': id},
      );
    }

    // 工作区是会话的一部分。先清理目录，清理失败时保留数据库记录，
    // 让用户可以重试而不是得到一个指向残留目录的幽灵会话。
    await _workspaces.deleteSessionDirectory(
      id,
      workspaceRoot: record.workspaceRoot,
    );
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
  ///
  /// 如果**当前会话**正在生成，改走排队式引导（协议 §10.4）：消息先落库、
  /// 再进队列，等上一批工具全部执行完才并进上下文。中途打断正在跑的工具
  /// 是不行的——副作用已经发生，模型却看不到结果，等于留下一个没有下文的
  /// 操作。
  ///
  /// 生成的是**别的**会话就照旧丢弃：插话只对"用户正看着的这一轮"有意义，
  /// 把 A 会话的话塞进 B 会话的历史不是用户的意思。全局单 run 是刻意简化
  /// （见 [_run]），这条分支不改那个决定。
  Future<void> sendMessage(
    String text, {
    List<PendingAttachment> attachments = const <PendingAttachment>[],
  }) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;

    final _RunState? run = _run;
    if (run != null) {
      if (run.sessionId == _activeId) {
        await _queueSteering(run, trimmed, attachments: attachments);
      }
      return;
    }

    final ChatSession session = active;
    await _askWithUserMessage(
      session,
      trimmed,
      attachments: attachments,
      isFirst: session.messages.isEmpty,
    );
  }

  /// 生成中收下一条用户输入，排队等下一次安全注入点（协议 §10.4）。
  ///
  /// **先落库再入队**：用户按了发送，这条消息就不该有丢失的路径——和
  /// [_askWithUserMessage] 同一条理由。落库用的是和普通用户消息同一套
  /// payload，所以它本来就会出现在以后每一轮的上下文里；队列只负责让
  /// **这一次**运行也看到它。
  Future<void> _queueSteering(
    _RunState run,
    String text, {
    required List<PendingAttachment> attachments,
  }) async {
    final Map<String, Object?> payload = _userEntryPayload(text, attachments);
    final String entryId = Ulid.generate();
    await _storage.appendEntry(
      run.sessionId,
      NewEntry(
        id: entryId,
        type: EntryType.message,
        role: EntryRole.user,
        payload: payload,
      ),
      preview: text,
    );

    // sendMessage 已经挡掉"既没文字也没附件"，这里必然还原得出一条消息。
    run.queue.add(
      _QueuedInput(
        entryId: entryId,
        message: _userMessageOf(payload)!,
      ),
    );

    _insertQueuedBubble(run.sessionId, entryId, text, attachments);
  }

  /// 在界面上插一条"排队中"气泡，排在流式草稿下面。
  ///
  /// 不 `_reload`：reload 会把正在生成的草稿整条冲掉，而这轮还没结束。
  void _insertQueuedBubble(
    String sessionId,
    String entryId,
    String text,
    List<PendingAttachment> attachments,
  ) {
    final int index = _sessions.indexWhere((ChatSession s) => s.id == sessionId);
    if (index < 0) return;

    final ChatSession session = _sessions[index];
    final ChatMessage bubble = ChatMessage(
      id: entryId,
      role: ChatRole.user,
      time: _timeLabel(DateTime.now()),
      rawText: text,
      queued: true,
      attachments: <Attachment>[
        for (final PendingAttachment a in attachments)
          _displayAttachment(
            name: a.name,
            mimeType: a.mimeType,
            base64Data: base64Encode(a.bytes),
          ),
      ],
      blocks: text.isEmpty
          ? const <ContentBlock>[]
          : <ContentBlock>[ParagraphBlock(text)],
    );

    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(
        messages: <ChatMessage>[...session.messages, bubble],
      );
    notifyListeners();
  }

  /// loop 在安全注入点取走排队输入（协议 §10.4）。
  ///
  /// 取走的同时把那些气泡转成普通用户消息——它们已经交给模型了，再挂着
  /// "排队中"就是在骗用户。
  List<ai.ChatMessageModel> takeQueuedInputs(_RunState run) {
    if (run.queue.isEmpty) return const <ai.ChatMessageModel>[];
    final List<_QueuedInput> taken = List<_QueuedInput>.of(run.queue);
    run.queue.clear();
    _markDelivered(
      run.sessionId,
      <String>{for (final _QueuedInput input in taken) input.entryId},
    );
    return <ai.ChatMessageModel>[
      for (final _QueuedInput input in taken) input.message,
    ];
  }

  /// 把已经交给模型的排队气泡转成普通用户消息。
  void _markDelivered(String sessionId, Set<String> entryIds) {
    if (entryIds.isEmpty) return;
    final int index = _sessions.indexWhere((ChatSession s) => s.id == sessionId);
    if (index < 0) return;

    final ChatSession session = _sessions[index];
    bool changed = false;
    final List<ChatMessage> updated = <ChatMessage>[];
    for (final ChatMessage message in session.messages) {
      if (message.queued && entryIds.contains(message.id)) {
        updated.add(message.copyWith(queued: false));
        changed = true;
      } else {
        updated.add(message);
      }
    }
    if (!changed) return;

    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(messages: updated);
    notifyListeners();
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
        payload: _userEntryPayload(text, attachments),
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

  /// Stops runtime work before AppBootstrap closes the database.
  Future<void> shutdown() => _shutdown ??= _stopRuntime();

  Future<void> _stopRuntime() async {
    final _RunState? run = _run;
    run?.source.cancel();
    await mcp.close();
    await run?.done.future;
  }

  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _run?.source.cancel();
    mcp.dispose();
    super.dispose();
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

      switch (entry.role) {
        case EntryRole.user:
          final ai.ChatMessageModel? message = _userMessageOf(entry.payload);
          if (message != null) history.add(message);
        case EntryRole.assistant:
          // thinking 不回传：跨模型时别人的思考块会被拒（§6-15），而重放
          // 自己的思考也没有收益。正文为空的轮次直接跳过。
          final String text = entry.payload['text'] as String? ?? '';
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

    // 别处可能留着上一段的流式气泡（插话会把一轮切成两条气泡），它们不再
    // 是"正在生成的这条"：光标只跟随本次草稿。
    final List<ChatMessage> ordered = <ChatMessage>[
      for (final ChatMessage m in session.messages)
        if (m.id != draft.bubbleId)
          m.isStreaming ? m.copyWith(isStreaming: false) : m,
    ];
    // 草稿插在排队消息前面：用户是在这一轮生成中途打的字，气泡该待在自己
    // 那句话上面，而不是被下一帧的草稿顶到下面去。
    int at = ordered.length;
    for (int i = 0; i < ordered.length; i++) {
      if (ordered[i].queued) {
        at = i;
        break;
      }
    }
    ordered.insert(at, bubble);

    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(messages: ordered);
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
      includeDirectories: true,
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
        includeDirectories: true,
      );
      result.add(session.copyWith(files: files));
    }
    return result;
  }
}

/// 生成中的一次运行。
class _RunState {
  _RunState({required this.sessionId, required this.source});

  final String sessionId;
  final CancellationTokenSource source;
  final Completer<void> done = Completer<void>();

  /// 生成期间用户打进来、还没并进上下文的话（排队式引导，协议 §10.4）。
  ///
  /// 队列放在会话层而不是 loop 里：谁在跑、气泡怎么显示、条目落到哪都是
  /// 会话状态，loop 只负责在正确的时机把它取走（`takePendingInputs`）。
  final List<_QueuedInput> queue = <_QueuedInput>[];
}

/// 一条排队中的用户输入：落库用的条目 id + 送进模型的形态。
///
/// 两个都要留着——`entryId` 用来把界面上那条"排队中"气泡转成普通消息，
/// `message` 用来注入历史。
class _QueuedInput {
  const _QueuedInput({required this.entryId, required this.message});

  final String entryId;
  final ai.ChatMessageModel message;
}

/// 界面一次装载的条目数上限。翻页靠 `readTail(beforeSeq:)`。
const int _kTailLimit = 50;
