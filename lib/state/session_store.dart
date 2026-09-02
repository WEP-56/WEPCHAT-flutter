import 'dart:async';

import 'package:flutter/foundation.dart';

import '../ai/messages.dart' as ai;
import '../ai/model_catalog.dart';
import '../ai/provider_api.dart';
import '../ai/provider_config.dart';
import '../ai/provider_factory.dart';
import '../ai/stream_event.dart';
import '../core/cancellation_token.dart';
import '../core/errors.dart';
import '../core/ulid.dart';
import '../models/chat.dart';
import '../models/content.dart';
import '../models/markdown_blocks.dart';
import '../models/workspace.dart';
import '../platform/workspace_paths.dart';
import '../storage/storage.dart';
import 'app_settings.dart';
import 'chat_turn.dart';

/// 会话列表与当前会话的可变状态，背后是真存储（实施 TODO §9-12、M1）。
///
/// 构造前必须先 [load]：会话列表在首帧之前就绪，界面不需要处理"加载中"
/// 状态，也就不需要为接存储改一行 UI 代码。
///
/// M1 起 [sendMessage] 会真的发请求：解析会话模型 → 建适配器 → 流式接收 →
/// 落库。**不走 `AgentLoop`**——纯聊天路径只需要适配器，先把这条链路验通，
/// 工具、权限、循环留到之后接（用户定的顺序）。
class SessionStore extends ChangeNotifier {
  SessionStore._({
    required WepStorage storage,
    required WorkspaceRoots workspaces,
    required AppSettings settings,
    required List<ChatSession> sessions,
    required String activeId,
  })  : _storage = storage,
        _workspaces = workspaces,
        _settings = settings,
        _sessions = sessions,
        _activeId = activeId;

  /// 打开存储里的会话列表，必要时补一个空会话。
  ///
  /// 默认模型取自 [settings]，可能为 null——用户还没配任何 provider 时就是
  /// 这种状态，会话照样能建，点发送时才提示。
  static Future<SessionStore> load({
    required WepStorage storage,
    required WorkspaceRoots workspaces,
    required AppSettings settings,
  }) async {
    final List<ChatSession> sessions = await _loadAll(storage);

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
    final SessionRecord record =
        await _createRecord(_storage, _workspaces, model);
    final ChatSession session = _toChatSession(record, const <EntryRecord>[]);
    _sessions = <ChatSession>[session, ..._sessions];
    _activeId = session.id;
    notifyListeners();
    return session;
  }

  /// 删除会话；删掉最后一个时补一个空会话，保证 [active] 始终有值。
  Future<void> deleteSession(
    String id, {
    required String fallbackModel,
  }) async {
    if (_sessions.every((ChatSession s) => s.id != id)) {
      throw ArgumentError.value(id, 'id', '会话不存在');
    }
    await _storage.deleteSession(id);
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

  /// 落一条用户消息，然后请模型回复。
  ///
  /// 首条消息顺带把标题从"新会话"改成用户第一句话（功能协议 §2.1）。
  /// 用户消息**先落库**再考虑能不能发请求：没配 key 的时候把用户刚打的字
  /// 丢掉是最糟的处理方式，输入框那边已经清空了。
  Future<void> sendMessage(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    if (_run != null) return; // 同时只跑一个。

    final ChatSession session = active;
    final bool isFirst = session.messages.isEmpty;

    await _storage.appendEntry(
      session.id,
      NewEntry(
        id: Ulid.generate(),
        type: EntryType.message,
        role: EntryRole.user,
        payload: <String, Object?>{'text': trimmed},
      ),
      preview: trimmed,
    );

    if (isFirst) {
      await _storage.renameSession(session.id, _titleFrom(trimmed));
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

  /// 解析模型与 provider，跑一轮请求。
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
      await _streamReply(
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

  /// 把存储里的历史条目翻成请求用的消息列表。
  ///
  /// 从 `base_seq` 起读（压缩之后只发摘要以后的部分），并丢掉 error /
  /// aborted 的轮次——半句话和没有结果的调用留在上下文里只会误导模型
  /// （§6-14）。
  Future<List<ai.ChatMessageModel>> _readHistory(String sessionId) async {
    final List<EntryRecord> entries = await _storage.readContext(sessionId);
    final List<ai.ChatMessageModel> history = <ai.ChatMessageModel>[];

    for (final EntryRecord entry in entries) {
      if (entry.type != EntryType.message) continue;
      if (!entry.isUsableInContext) continue;

      final String text = entry.payload['text'] as String? ?? '';
      switch (entry.role) {
        case EntryRole.user:
          if (text.isNotEmpty) history.add(ai.ChatMessageModel.user(text));
        case EntryRole.assistant:
          // thinking 不回传：跨模型时别人的思考块会被拒（§6-15），而纯聊天
          // 路径下重放自己的思考也没有收益。正文为空的轮次直接跳过。
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

  /// 消费事件流，边收边重绘，结束时落库。
  Future<void> _streamReply({
    required ProviderApi api,
    required ModelSpec model,
    required String sessionId,
    required List<ai.ChatMessageModel> history,
    required String runId,
    required CancellationToken token,
  }) async {
    final ProviderRequest request = ProviderRequest(
      model: model,
      messages: history,
      tools: const <ToolDefinition>[],
      maxOutputTokens: model.maxOutputTokens,
      // o 系列拒收 temperature，靠模型的兼容开关决定发不发（§4.2）。
      temperature:
          model.compat.supportsTemperature ? _settings.temperature : null,
      sessionId: sessionId,
    );

    // 流式气泡的 id 只生成一次：每帧换 id 会让 ListView 认为是新元素，
    // 打字过程中整条消息会闪。
    final String bubbleId = Ulid.generate();
    ai.ChatMessageModel? last;

    try {
      await for (final StreamEvent event in api.stream(request, token)) {
        last = event.message;
        _paintStreaming(sessionId, bubbleId, event.message);
      }
    } on Object catch (e) {
      // 适配器承诺不抛（§4-2），这里只是兜底：真抛了也不能让 run 悬着。
      _notice = '生成失败：$e';
      await _storage.finishRun(runId, RunOutcome.error);
      await _reload(sessionId);
      return;
    }

    if (last == null) {
      _notice = '没有收到任何响应';
      await _storage.finishRun(runId, RunOutcome.error);
      await _reload(sessionId);
      return;
    }

    final ai.StopReason reason = last.stopReason ?? ai.StopReason.stop;

    // 一个字都没吐出来就被中断：不留空气泡，直接当这一轮没发生过。
    if (reason == ai.StopReason.aborted && last.text.trim().isEmpty) {
      await _storage.finishRun(runId, RunOutcome.aborted);
      await _reload(sessionId);
      return;
    }

    await _persistAssistant(sessionId, last, reason);
    await _storage.finishRun(runId, _outcomeOf(reason));
    await _reload(sessionId);
  }

  /// 把 partial 消息画到界面上。
  ///
  /// 只改内存里的那一条，不落库——流式过程中每个 delta 都写一次库既慢又
  /// 违反"条目写入即不可变"（存储设计 §7.1）。落库在流结束时一次完成。
  void _paintStreaming(
    String sessionId,
    String bubbleId,
    ai.ChatMessageModel message,
  ) {
    final int index = _sessions.indexWhere((ChatSession s) => s.id == sessionId);
    if (index < 0) return;

    final ChatSession session = _sessions[index];
    final ChatMessage bubble = ChatMessage(
      id: bubbleId,
      isUser: false,
      time: _timeLabel(DateTime.now()),
      blocks: _blocksOf(
        text: message.text,
        thinking: message.thinkingText,
        error: null,
      ),
      isStreaming: true,
    );

    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = session.copyWith(
        messages: <ChatMessage>[
          for (final ChatMessage m in session.messages)
            if (m.id != bubbleId) m,
          bubble,
        ],
      );
    notifyListeners();
  }

  /// 落一条助手消息。
  ///
  /// `stopReason` 进独立的列而不是 payload：出错和被中断的轮次要在不解析
  /// payload 的前提下排除出上下文（`EntryRecord.isUsableInContext`）。
  Future<void> _persistAssistant(
    String sessionId,
    ai.ChatMessageModel message,
    ai.StopReason reason,
  ) async {
    final String text = message.text;
    final String thinking = message.thinkingText;

    final Map<String, Object?> payload = <String, Object?>{'text': text};
    if (thinking.isNotEmpty) payload['thinking'] = thinking;
    // 失败原因写进 payload 而不是丢掉：用户要看得见"为什么没回复"，
    // 而这条消息本身已经被 stopReason 挡在下次请求之外了。
    if (message.errorMessage != null) payload['error'] = message.errorMessage;

    await _storage.appendEntry(
      sessionId,
      NewEntry(
        id: Ulid.generate(),
        type: EntryType.message,
        role: EntryRole.assistant,
        payload: payload,
        tokenEst: message.usage.outputTokens,
        stopReason: toStorageStopReason(reason),
        usage: toStorageTokenUsage(message.usage),
      ),
      preview: text.isEmpty ? (message.errorMessage ?? '生成失败') : text,
    );
  }

  static RunOutcome _outcomeOf(ai.StopReason reason) {
    return switch (reason) {
      ai.StopReason.error => RunOutcome.error,
      ai.StopReason.aborted => RunOutcome.aborted,
      ai.StopReason.stop ||
      ai.StopReason.toolUse ||
      ai.StopReason.length =>
        RunOutcome.completed,
    };
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

    final int index = _sessions.indexWhere((ChatSession s) => s.id == sessionId);
    if (index < 0) return;
    _sessions = List<ChatSession>.of(_sessions)..[index] = updated;
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

  static Future<List<ChatSession>> _loadAll(WepStorage storage) async {
    final List<SessionSummary> summaries = await storage.listSessions();
    final List<ChatSession> result = <ChatSession>[];

    for (final SessionSummary summary in summaries) {
      final SessionRecord? record = await storage.findSession(summary.id);
      if (record == null) continue; // 列表与详情之间被删了，跳过。
      final List<EntryRecord> entries = await storage.readTail(
        summary.id,
        limit: _kTailLimit,
      );
      result.add(_toChatSession(record, entries));
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
      files: const <WorkspaceFile>[],
      messages: <ChatMessage>[
        for (final EntryRecord e in entries)
          if (e.type == EntryType.message) _toChatMessage(e),
      ],
    );
  }

  static ChatMessage _toChatMessage(EntryRecord entry) {
    final bool isUser = entry.role == EntryRole.user;
    final String text = entry.payload['text'] as String? ?? '';

    return ChatMessage(
      id: entry.id,
      isUser: isUser,
      time: _timeLabel(entry.createdAt),
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
        .difference(
          DateTime(updatedAt.year, updatedAt.month, updatedAt.day),
        )
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
