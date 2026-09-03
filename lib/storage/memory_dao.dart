import 'package:sqlite3/sqlite3.dart';

import 'memory_record.dart';

/// `memories` 表的读写。
///
/// 只在 DB isolate 内使用——`sqlite3` 的 [Database] 句柄不可跨 isolate
/// 传递（存储设计 §10）。
class MemoryDao {
  MemoryDao(this._db);

  final Database _db;

  /// 列出所有记忆的摘要，按更新时间倒序。
  ///
  /// [category] 非空时只返回该分类的记忆。
  /// 摘要只含前 100 字符，不含完整 content。
  List<MemorySummary> listSummaries({String? category}) {
    final String sql = category == null
        ? '''
SELECT id, category, key,
       SUBSTR(content, 1, 100) AS summary,
       updated_at
FROM memories
ORDER BY updated_at DESC'''
        : '''
SELECT id, category, key,
       SUBSTR(content, 1, 100) AS summary,
       updated_at
FROM memories
WHERE category = ?
ORDER BY updated_at DESC''';

    final ResultSet rows = category == null
        ? _db.select(sql)
        : _db.select(sql, <Object?>[category]);

    return rows.map(_toSummary).toList(growable: false);
  }

  /// 按 ID 读取完整记忆。
  MemoryRecord? findById(String id) {
    final ResultSet rows = _db.select(
      'SELECT * FROM memories WHERE id = ?',
      <Object?>[id],
    );
    if (rows.isEmpty) return null;
    return _toRecord(rows.first);
  }

  /// 按 category + key 查找记忆。
  MemoryRecord? findByCategoryKey(String category, String key) {
    final ResultSet rows = _db.select(
      'SELECT * FROM memories WHERE category = ? AND key = ?',
      <Object?>[category, key],
    );
    if (rows.isEmpty) return null;
    return _toRecord(rows.first);
  }

  /// 插入或更新记忆。
  ///
  /// 相同 `category + key` 时覆盖（ON CONFLICT REPLACE），否则新增。
  void upsert(MemoryRecord memory) {
    _db.execute(
      '''
INSERT INTO memories (id, category, key, content, tags, created_at, updated_at)
VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(category, key)
DO UPDATE SET
  id = excluded.id,
  content = excluded.content,
  tags = excluded.tags,
  updated_at = excluded.updated_at''',
      <Object?>[
        memory.id,
        memory.category,
        memory.key,
        memory.content,
        memory.tags,
        memory.createdAt.millisecondsSinceEpoch,
        memory.updatedAt.millisecondsSinceEpoch,
      ],
    );
  }

  /// 删除指定记忆。
  void delete(String id) {
    _db.execute('DELETE FROM memories WHERE id = ?', <Object?>[id]);
    // 注意：sqlite3 的 execute 返回 void，不能检查 affected rows。
    // 如果需要检查是否真的删除了，需要先 SELECT 验证存在。
  }

  MemorySummary _toSummary(Row row) {
    return MemorySummary(
      id: row['id'] as String,
      category: row['category'] as String,
      key: row['key'] as String,
      summary: row['summary'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }

  MemoryRecord _toRecord(Row row) {
    return MemoryRecord(
      id: row['id'] as String,
      category: row['category'] as String,
      key: row['key'] as String,
      content: row['content'] as String,
      tags: row['tags'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(row['updated_at'] as int),
    );
  }
}
