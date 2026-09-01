import '../core/ulid.dart';
import 'blob_store.dart';
import 'entry_record.dart';
import 'isolate_protocol.dart';
import 'models.dart';
import 'session_record.dart';
import 'storage_isolate.dart';

/// 存储层的唯一公开入口。
///
/// 上层只见这一个类，看不到 sqlite3、isolate 协议和 DAO。换掉底层实现
/// （例如将来加只读连接做并发读）不影响调用方。
class WepStorage {
  WepStorage._(this._isolate);

  /// 打开存储。[dbPath] 与 [blobRoot] 由 platform 层解析
  /// （见 `platform/app_paths.dart`）。
  static Future<WepStorage> open({
    required String dbPath,
    required String blobRoot,
  }) async {
    final StorageIsolate isolate = await StorageIsolate.spawn(
      dbPath: dbPath,
      blobRoot: blobRoot,
    );
    return WepStorage._(isolate);
  }

  final StorageIsolate _isolate;

  // ---- 会话 ----

  /// 会话列表。只读元信息，不读 payload。
  Future<List<SessionSummary>> listSessions({int limit = 200}) {
    return _isolate.send<List<SessionSummary>>(
      (int id) => ListSessionSummariesRequest(id, limit: limit),
    );
  }

  Future<SessionRecord?> findSession(String sessionId) {
    return _isolate.send<SessionRecord?>(
      (int id) => FindSessionRequest(id, sessionId),
    );
  }

  /// 新建会话。会话 id 是 ULID，同时作为工作区目录名（功能协议 §2.1）。
  Future<SessionRecord> createSession({
    required String title,
    required String workspaceRoot,
    required String providerId,
    required String modelId,
    ThinkingLevel thinking = ThinkingLevel.off,
  }) async {
    final DateTime now = DateTime.now();
    final SessionRecord session = SessionRecord(
      id: Ulid.generate(),
      title: title,
      createdAt: now,
      updatedAt: now,
      workspaceRoot: workspaceRoot,
      providerId: providerId,
      modelId: modelId,
      thinking: thinking,
      preview: '',
      headSeq: 0,
      baseSeq: 0,
      contextTokens: 0,
      costTotal: 0,
    );
    await _isolate.send<Object?>((int id) => CreateSessionRequest(id, session));
    return session;
  }

  Future<void> renameSession(String sessionId, String title) {
    return _isolate.send<Object?>(
      (int id) => RenameSessionRequest(id, sessionId, title),
    );
  }

  /// 删除会话。**不删工作区目录**——那是用户产物，由上层确认意图后处理。
  Future<void> deleteSession(String sessionId) {
    return _isolate.send<Object?>(
      (int id) => DeleteSessionRequest(id, sessionId),
    );
  }

  // ---- 条目 ----

  /// 追加一条条目，返回事务内分配的 `seq`。
  ///
  /// [preview] / [contextTokens] / [costDelta] 非空时一并更新会话汇总列，
  /// 与插入同事务（存储设计 §6.1）。
  Future<int> appendEntry(
    String sessionId,
    NewEntry entry, {
    String? preview,
    int? contextTokens,
    double? costDelta,
  }) {
    return _isolate.send<int>(
      (int id) => AppendEntryRequest(
        id,
        sessionId,
        entry,
        preview: preview,
        contextTokens: contextTokens,
        costDelta: costDelta,
      ),
    );
  }

  /// 组装上下文用：读 `seq >= base_seq` 的全部条目，顺序。
  ///
  /// 成本只与压缩点之后的条目数相关，与会话总长无关（存储设计 §13）。
  Future<List<EntryRecord>> readContext(String sessionId) {
    return _isolate.send<List<EntryRecord>>(
      (int id) => ReadContextRequest(id, sessionId),
    );
  }

  /// 界面分页用：尾部 N 条，按 `seq` 升序返回。
  ///
  /// 翻页时把上一页最小的 `seq` 传给 [beforeSeq]。
  Future<List<EntryRecord>> readTail(
    String sessionId, {
    int limit = 50,
    int? beforeSeq,
  }) {
    return _isolate.send<List<EntryRecord>>(
      (int id) =>
          ReadTailRequest(id, sessionId, limit: limit, beforeSeq: beforeSeq),
    );
  }

  /// 读 `*_change` 条目，用于回放派生状态（存储设计 §7.3）。
  Future<List<EntryRecord>> readStateChanges(String sessionId) {
    return _isolate.send<List<EntryRecord>>(
      (int id) => ReadDerivedStateRequest(id, sessionId),
    );
  }

  /// 换模型：追加 `model_change` 条目并更新缓存列，同事务。
  Future<int> changeModel(
    String sessionId, {
    required String providerId,
    required String modelId,
  }) {
    return _isolate.send<int>(
      (int id) => ChangeModelRequest(
        id,
        sessionId,
        entryId: Ulid.generate(),
        providerId: providerId,
        modelId: modelId,
      ),
    );
  }

  /// 换思考档位：追加 `thinking_change` 条目并更新缓存列，同事务。
  Future<int> changeThinking(String sessionId, ThinkingLevel thinking) {
    return _isolate.send<int>(
      (int id) => ChangeThinkingRequest(
        id,
        sessionId,
        entryId: Ulid.generate(),
        thinking: thinking,
      ),
    );
  }

  /// 压缩会话：写一条 `compaction` 摘要并把上下文起点移到它（存储设计 §7.2）。
  ///
  /// 返回摘要条目的 seq，也就是新的 `base_seq`。
  ///
  /// 摘要文本由调用方生成（通常是让模型总结 `readContext` 的结果）——存储层
  /// 只负责原子地落盘和移动起点，不关心摘要怎么来的。
  ///
  /// [replacedThrough] 是这条摘要覆盖到的最后一个 seq，仅作记录：真正决定
  /// 上下文范围的是 `base_seq`。两者分开是为了将来能查"这段摘要总结了哪些条目"。
  Future<int> compressSession(
    String sessionId, {
    required String summary,
    required int replacedThrough,
    int tokenEst = 0,
  }) {
    return _isolate.send<int>(
      (int id) => CompressSessionRequest(
        id,
        sessionId,
        entryId: Ulid.generate(),
        summary: summary,
        replacedThrough: replacedThrough,
        tokenEst: tokenEst,
      ),
    );
  }

  // ---- run 与维护 ----

  /// 开始一次 run，返回 run id。
  Future<String> startRun(String sessionId) async {
    final String runId = Ulid.generate();
    await _isolate.send<Object?>(
      (int id) => StartRunRequest(id, runId, sessionId),
    );
    return runId;
  }

  Future<void> finishRun(String runId, RunOutcome outcome) {
    return _isolate.send<Object?>(
      (int id) => FinishRunRequest(id, runId, outcome),
    );
  }

  /// 启动时调用：把未结束的 run 标为中断，返回受影响的会话 id。
  ///
  /// 界面据此显示"上次回复被中断，可重试"（存储设计 §6.2）。
  Future<List<String>> reconcileInterruptedRuns() {
    return _isolate.send<List<String>>(ReconcileInterruptedRunsRequest.new);
  }

  /// blob GC。倾向"删除会话时立即 + 启动时兜底扫描"
  /// （存储设计 §14 第 5 条）。
  Future<BlobGcResult> collectBlobGarbage() {
    return _isolate.send<BlobGcResult>(CollectBlobGarbageRequest.new);
  }

  Future<void> close() => _isolate.close();
}
