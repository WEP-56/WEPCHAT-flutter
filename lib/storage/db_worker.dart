import 'dart:io';

import 'package:sqlite3/sqlite3.dart';

import '../core/errors.dart';
import 'blob_store.dart';
import 'entry_dao.dart';
import 'entry_record.dart';
import 'isolate_protocol.dart';
import 'migration.dart';
import 'models.dart';
import 'run_dao.dart';
import 'session_dao.dart';
import 'session_record.dart';

/// DB isolate 内的实际执行者：持唯一写连接，串行处理请求。
///
/// 不导出给 UI 层——外部只经 [StorageIsolate] 访问（存储设计 §10）。
class DbWorker {
  DbWorker._(this._db, this._sessions, this._entries, this._runs, this._blobs);

  /// 打开库、跑迁移、装配 DAO。在 isolate 内调用。
  factory DbWorker.open({required String dbPath, required String blobRoot}) {
    final Database db = openAndMigrate(dbPath);
    try {
      final BlobStore blobs = BlobStore(db, Directory(blobRoot));
      return DbWorker._(
        db,
        SessionDao(db),
        EntryDao(db, blobs),
        RunDao(db),
        blobs,
      );
    } on Object {
      db.dispose();
      rethrow;
    }
  }

  final Database _db;
  final SessionDao _sessions;
  final EntryDao _entries;
  final RunDao _runs;
  final BlobStore _blobs;

  /// 分派一个请求。返回值直接进 [DbSuccess]。
  Object? handle(DbRequest request) {
    switch (request) {
      case ListSessionSummariesRequest(:final int limit):
        return _sessions.listSummaries(limit: limit);

      case FindSessionRequest(:final String sessionId):
        return _sessions.findById(sessionId);

      case CreateSessionRequest(:final SessionRecord session):
        _sessions.insert(session);
        return null;

      case RenameSessionRequest(:final String sessionId, :final String title):
        _sessions.updateTitle(sessionId, title, _now());
        return null;

      case AppendEntryRequest():
        return _appendEntry(request);

      case ReadContextRequest(:final String sessionId):
        return _entries.readFromBaseSeq(sessionId);

      case ReadTailRequest(
        :final String sessionId,
        :final int limit,
        :final int? beforeSeq,
      ):
        return _entries.readTail(sessionId, limit: limit, beforeSeq: beforeSeq);

      case ReadDerivedStateRequest(:final String sessionId):
        return _entries.readStateChanges(sessionId);

      case ChangeModelRequest():
        return _changeModel(request);

      case ChangeThinkingRequest():
        return _changeThinking(request);

      case CompressSessionRequest():
        return _compressSession(request);

      case DeleteSessionRequest(:final String sessionId):
        _deleteSession(sessionId);
        return null;

      case StartRunRequest(:final String runId, :final String sessionId):
        _runs.start(runId, sessionId, _now());
        return null;

      case FinishRunRequest(:final String runId, :final RunOutcome outcome):
        _runs.finish(runId, outcome, _now());
        return null;

      case ReconcileInterruptedRunsRequest():
        return _runs.reconcileInterrupted(_now());

      case CollectBlobGarbageRequest():
        return _inTransaction(() => _blobs.collectGarbage());

      case ShutdownRequest():
        // 关闭由消息循环处理，这里不该收到。
        throw const StorageError('ShutdownRequest 不应进入 handle');
    }
  }

  int _appendEntry(AppendEntryRequest r) {
    return _inTransaction(() {
      final AppendedEntry appended = _entries.append(
        r.sessionId,
        r.entry,
        now: _now(),
        preview: r.preview,
        contextTokens: r.contextTokens,
        costDelta: r.costDelta,
      );
      return appended.seq;
    });
  }

  /// 追加 `model_change` 条目并更新缓存列。
  ///
  /// 两步必须同事务：缓存列的权威值是条目回放的结果（存储设计 §7.3），
  /// 分成两个事务后中途崩溃会让两者分叉，而分叉被定义为 bug 而非可容忍状态。
  int _changeModel(ChangeModelRequest r) {
    return _inTransaction(() {
      final AppendedEntry appended = _entries.append(
        r.sessionId,
        NewEntry(
          id: r.entryId,
          type: EntryType.modelChange,
          // 字段顺序影响 payload 字节，进而影响 prompt cache 前缀，勿动
          // （实施 TODO §6-5）。
          payload: <String, Object?>{
            'providerId': r.providerId,
            'modelId': r.modelId,
          },
        ),
        now: _now(),
      );
      _sessions.updateDerivedCache(
        r.sessionId,
        now: _now(),
        providerId: r.providerId,
        modelId: r.modelId,
      );
      return appended.seq;
    });
  }

  /// 追加 `compaction` 条目，并把 `base_seq` 推到这条（存储设计 §7.2）。
  ///
  /// 同事务的理由和 `_changeModel` 一样，但后果更重：`base_seq` 是组装上下文
  /// 的唯一起点，它和摘要条目分叉意味着整段历史要么重复出现要么整体消失。
  ///
  /// 摘要条目本身也参与取号，所以它的 seq 一定大于被它覆盖的全部条目
  /// ——`base_seq` 指向它之后，读上下文自然只拿到"摘要 + 之后的新条目"。
  int _compressSession(CompressSessionRequest r) {
    return _inTransaction(() {
      final AppendedEntry appended = _entries.append(
        r.sessionId,
        NewEntry(
          id: r.entryId,
          type: EntryType.compaction,
          tokenEst: r.tokenEst,
          // 字段顺序影响 payload 字节，进而影响 prompt cache 前缀，勿动。
          payload: <String, Object?>{
            'summary': r.summary,
            'replacedThrough': r.replacedThrough,
          },
        ),
        now: _now(),
      );
      _sessions.updateBaseSeq(r.sessionId, appended.seq, _now());
      return appended.seq;
    });
  }

  int _changeThinking(ChangeThinkingRequest r) {
    return _inTransaction(() {
      final AppendedEntry appended = _entries.append(
        r.sessionId,
        NewEntry(
          id: r.entryId,
          type: EntryType.thinkingChange,
          payload: <String, Object?>{'thinking': r.thinking.wire},
        ),
        now: _now(),
      );
      _sessions.updateDerivedCache(
        r.sessionId,
        now: _now(),
        thinking: r.thinking,
      );
      return appended.seq;
    });
  }

  /// 删除会话（存储设计 §9-11）。
  ///
  /// 顺序：软删 → 删 blob_refs → 硬删行（`entries` / `runs` 靠外键级联）。
  /// 工作区目录**不在这里删**——那是用户产物，由上层确认意图后处理
  /// （功能协议 §2.1）。
  void _deleteSession(String sessionId) {
    _inTransaction(() {
      final DateTime now = _now();
      _sessions.softDelete(sessionId, now);
      _blobs.removeSessionRefs(sessionId);
      _sessions.hardDelete(sessionId);
      return null;
    });
  }

  /// 包一层事务。嵌套调用会失败——SQLite 不支持嵌套 BEGIN，所以
  /// [handle] 的每个分支只能进一次。
  T _inTransaction<T>(T Function() body) {
    _db.execute('BEGIN');
    try {
      final T result = body();
      _db.execute('COMMIT');
      return result;
    } on Object {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  void dispose() {
    _db.dispose();
  }

  /// 时间统一从这里取，方便将来注入固定时钟做测试。
  DateTime _now() => DateTime.now();
}
