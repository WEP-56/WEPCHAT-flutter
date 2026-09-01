import 'package:flutter/foundation.dart';

import '../core/ulid.dart';
import '../models/chat.dart';
import '../models/content.dart';
import '../models/workspace.dart';
import '../platform/workspace_paths.dart';
import '../storage/storage.dart';

/// 会话列表与当前会话的可变状态，背后是真存储（实施 TODO §9-12）。
///
/// 构造前必须先 [load]：会话列表在首帧之前就绪，界面不需要处理"加载中"
/// 状态，也就不需要为接存储改一行 UI 代码。
///
/// M0 只落用户消息，不产生助手回复——回复由 M1 的 agent 事件流驱动。
class SessionStore extends ChangeNotifier {
  SessionStore._({
    required WepStorage storage,
    required WorkspaceRoots workspaces,
    required List<ChatSession> sessions,
    required String activeId,
  })  : _storage = storage,
        _workspaces = workspaces,
        _sessions = sessions,
        _activeId = activeId;

  /// 打开存储里的会话列表，必要时补一个空会话。
  ///
  /// [defaultModel] 来自设置里的默认模型（`kAvailableModels` 里的展示名）。
  static Future<SessionStore> load({
    required WepStorage storage,
    required WorkspaceRoots workspaces,
    required String defaultModel,
  }) async {
    final List<ChatSession> sessions = await _loadAll(storage);

    if (sessions.isEmpty) {
      // 空库首启：建一个会话，保证 [active] 始终有值（界面依赖这条不变量）。
      sessions.add(
        _toChatSession(
          await _createRecord(storage, workspaces, defaultModel),
          const <EntryRecord>[],
        ),
      );
    }

    return SessionStore._(
      storage: storage,
      workspaces: workspaces,
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
  List<ChatSession> _sessions;
  String _activeId;

  List<ChatSession> get sessions => List<ChatSession>.unmodifiable(_sessions);
  String get activeId => _activeId;

  /// M0 不产生助手回复，所以永远不在生成中。M1 接 agent 后由 run 状态驱动。
  bool get isGenerating => false;

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

  /// 新建空会话并切换过去。[model] 是 `kAvailableModels` 里的展示名。
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

  /// 落一条用户消息。
  ///
  /// M0 到此为止——没有 agent，就不伪造回复。首条消息顺带把标题从
  /// "新会话"改成用户第一句话（功能协议 §2.1）。
  Future<void> sendMessage(String text) async {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;

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
  }

  /// M0 没有生成中的请求可中断。M1 接 agent 后取消 [CancellationToken]。
  void stopGenerating() {}

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
      // 展示名原样存在 modelId 里，读回来直接用——拼成 "provider:model"
      // 会和模型选择器里的 `kAvailableModels` 对不上，勾选态永远是空的。
      model: record.modelId,
      files: const <WorkspaceFile>[],
      messages: <ChatMessage>[
        for (final EntryRecord e in entries)
          if (e.type == EntryType.message) _toChatMessage(e),
      ],
    );
  }

  static ChatMessage _toChatMessage(EntryRecord entry) {
    final String text = entry.payload['text'] as String? ?? '';
    return ChatMessage(
      id: entry.id,
      isUser: entry.role == EntryRole.user,
      time: _timeLabel(entry.createdAt),
      blocks: text.isEmpty
          ? const <ContentBlock>[]
          : <ContentBlock>[ParagraphBlock(text)],
    );
  }

  /// 展示名 → provider id。
  ///
  /// M0 的权宜之计：模型清单还是 mock 的展示名，没有真的 provider 注册表。
  /// M1 建了 provider 层之后，这个映射连同 `kAvailableModels` 一起删掉。
  static String _providerFor(String model) {
    final String lower = model.toLowerCase();
    if (lower.startsWith('gpt')) return 'openai';
    if (lower.startsWith('claude')) return 'anthropic';
    if (lower.startsWith('gemini')) return 'google';
    if (lower.startsWith('deepseek')) return 'deepseek';
    if (lower.startsWith('qwen')) return 'alibaba';
    return 'unknown';
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

/// 界面一次装载的条目数上限。翻页靠 `readTail(beforeSeq:)`。
const int _kTailLimit = 50;
