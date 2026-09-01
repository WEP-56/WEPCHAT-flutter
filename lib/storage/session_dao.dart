import 'package:sqlite3/sqlite3.dart';

import '../core/errors.dart';
import 'models.dart';
import 'session_record.dart';

/// `sessions` 表的读写。
///
/// 只在 DB isolate 内使用——`sqlite3` 的 [Database] 句柄不可跨 isolate
/// 传递（存储设计 §10）。
class SessionDao {
  SessionDao(this._db);

  final Database _db;

  /// 会话列表：只读元信息列，**不读 payload**（存储设计 §1 第三种读法）。
  ///
  /// 走 `sessions_recent` 索引，不做全表扫描。
  List<SessionSummary> listSummaries({int limit = 200}) {
    final ResultSet rows = _db.select(
      '''
SELECT id, title, updated_at, preview, model_id, context_tokens, cost_total
FROM sessions
WHERE deleted_at IS NULL
ORDER BY updated_at DESC
LIMIT ?''',
      <Object?>[limit],
    );

    return rows.map(_toSummary).toList(growable: false);
  }

  SessionRecord? findById(String id) {
    final ResultSet rows = _db.select(
      'SELECT * FROM sessions WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return _toRecord(rows.first);
  }

  /// 插入新会话。`head_seq` / `base_seq` 从 0 起，第一条条目取到 1。
  void insert(SessionRecord session) {
    _db.execute(
      '''
INSERT INTO sessions (
  id, title, created_at, updated_at, workspace_root,
  provider_id, model_id, thinking, preview,
  head_seq, base_seq, context_tokens, cost_total, deleted_at
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      <Object?>[
        session.id,
        session.title,
        session.createdAt.millisecondsSinceEpoch,
        session.updatedAt.millisecondsSinceEpoch,
        session.workspaceRoot,
        session.providerId,
        session.modelId,
        session.thinking.wire,
        session.preview,
        session.headSeq,
        session.baseSeq,
        session.contextTokens,
        session.costTotal,
        session.deletedAt?.millisecondsSinceEpoch,
      ],
    );
  }

  /// 改标题。只动 `title` 与 `updated_at`，不碰派生状态缓存列。
  void updateTitle(String id, String title, DateTime now) {
    _requireAffected(
      () => _db.execute(
        'UPDATE sessions SET title = ?, updated_at = ? WHERE id = ?',
        <Object?>[title, now.millisecondsSinceEpoch, id],
      ),
      id,
      'updateTitle',
    );
  }

  /// 把上下文起点推到 [baseSeq]（存储设计 §7.2）。
  ///
  /// 必须与追加 `compaction` 条目同事务：`base_seq` 指向那条摘要，先移后写
  /// 中途崩溃会让起点指向不存在的条目，组装上下文就会丢掉摘要之前的全部内容。
  ///
  /// 只许前进。`base_seq` 回退等于把已被摘要替代的原始条目重新纳入上下文，
  /// 那些条目的 token 已经算在摘要里，重新纳入会让上下文凭空变长。
  void updateBaseSeq(String id, int baseSeq, DateTime now) {
    final ResultSet rows = _db.select(
      'UPDATE sessions SET base_seq = ?, updated_at = ? '
      'WHERE id = ? AND base_seq <= ? RETURNING base_seq',
      <Object?>[baseSeq, now.millisecondsSinceEpoch, id, baseSeq],
    );
    if (rows.isEmpty) {
      throw StorageError(
        '会话不存在或 base_seq 不允许回退',
        context: <String, Object?>{'sessionId': id, 'baseSeq': baseSeq},
      );
    }
  }

  /// 更新派生状态缓存列。
  ///
  /// 权威值是 `*_change` 条目（存储设计 §7.3），所以这个方法必须与追加
  /// 对应条目在**同一个事务**里调用，否则缓存与日志会分叉。
  void updateDerivedCache(
    String id, {
    required DateTime now,
    String? providerId,
    String? modelId,
    ThinkingLevel? thinking,
  }) {
    final List<String> sets = <String>['updated_at = ?'];
    final List<Object?> args = <Object?>[now.millisecondsSinceEpoch];

    if (providerId != null) {
      sets.add('provider_id = ?');
      args.add(providerId);
    }
    if (modelId != null) {
      sets.add('model_id = ?');
      args.add(modelId);
    }
    if (thinking != null) {
      sets.add('thinking = ?');
      args.add(thinking.wire);
    }

    args.add(id);
    _requireAffected(
      () => _db.execute(
        'UPDATE sessions SET ${sets.join(', ')} WHERE id = ?',
        args,
      ),
      id,
      'updateDerivedCache',
    );
  }

  /// 软删除。硬删由删除流程的最后一步做（存储设计 §9-11）。
  void softDelete(String id, DateTime now) {
    _requireAffected(
      () => _db.execute(
        'UPDATE sessions SET deleted_at = ?, updated_at = ? WHERE id = ?',
        <Object?>[now.millisecondsSinceEpoch, now.millisecondsSinceEpoch, id],
      ),
      id,
      'softDelete',
    );
  }

  /// 硬删。`entries` / `runs` 靠 `ON DELETE CASCADE` 连带删除；
  /// `blob_refs` 没有外键约束，由调用方先清（存储设计 §5.3）。
  void hardDelete(String id) {
    _db.execute('DELETE FROM sessions WHERE id = ?', <Object?>[id]);
  }

  /// 软删除的会话 id，用于与工作区目录对账。
  List<String> listSoftDeletedIds() {
    final ResultSet rows = _db.select(
      'SELECT id FROM sessions WHERE deleted_at IS NOT NULL',
    );
    return rows.map((Row r) => r['id'] as String).toList(growable: false);
  }

  /// UPDATE 没命中任何行说明会话不存在。静默返回会让上层以为写成功了
  /// （AGENTS.md §1.3）。
  void _requireAffected(void Function() run, String id, String op) {
    run();
    if (_db.updatedRows == 0) {
      throw StorageError(
        '会话不存在，更新未生效',
        context: <String, Object?>{'sessionId': id, 'op': op},
      );
    }
  }

  static SessionSummary _toSummary(Row r) {
    return SessionSummary(
      id: r['id'] as String,
      title: r['title'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      preview: r['preview'] as String,
      modelId: r['model_id'] as String,
      contextTokens: r['context_tokens'] as int,
      costTotal: (r['cost_total'] as num).toDouble(),
    );
  }

  static SessionRecord _toRecord(Row r) {
    final int? deletedAt = r['deleted_at'] as int?;
    return SessionRecord(
      id: r['id'] as String,
      title: r['title'] as String,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updated_at'] as int),
      workspaceRoot: r['workspace_root'] as String,
      providerId: r['provider_id'] as String,
      modelId: r['model_id'] as String,
      thinking: ThinkingLevel.fromWire(r['thinking'] as String),
      preview: r['preview'] as String,
      headSeq: r['head_seq'] as int,
      baseSeq: r['base_seq'] as int,
      contextTokens: r['context_tokens'] as int,
      costTotal: (r['cost_total'] as num).toDouble(),
      deletedAt: deletedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(deletedAt),
    );
  }
}
