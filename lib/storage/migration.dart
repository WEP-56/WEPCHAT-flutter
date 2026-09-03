import 'package:sqlite3/sqlite3.dart';

import '../core/errors.dart';
import 'schema.dart';

/// 一次向前迁移。[toVersion] 是执行后的 `user_version`。
///
/// [statements] 只能含 DDL / DML——不能含 `PRAGMA journal_mode`
/// 之类不允许在事务内执行的语句（见 [kConnectionPragmas]）。
class Migration {
  const Migration(this.toVersion, this.statements);

  final int toVersion;
  final List<String> statements;
}

/// 迁移序列，按 `toVersion` 升序。只允许追加，不允许修改已发布的条目
/// ——用户库里已经执行过的语句改了也不会重跑，只会让新旧库结构分叉。
const List<Migration> kMigrations = <Migration>[
  Migration(1, kSchemaV1),
  Migration(2, kMigrationV2),
];

/// 打开数据库、应用连接级 PRAGMA、执行待办迁移。
///
/// 调用方负责最终 `db.dispose()`。失败时此函数已经关掉连接，不需要调用方兜底。
///
/// 抛出 [StorageError]：
/// - 库里的 `user_version` 高于代码支持的版本（用户装过新版又降级）
/// - 迁移语句执行失败
/// [migrations] 只在测试里传：生产代码用默认的 [kMigrations]。测试需要它
/// 才能真的跑一次"v1 库升到 v2"，而不是只验证"v1 库不用升"——目前发布的
/// 迁移只有一条，不注入就没有任何一条前进路径被执行过。
Database openAndMigrate(
  String path, {
  List<Migration> migrations = kMigrations,
}) {
  final Database db = sqlite3.open(path);
  try {
    for (final String pragma in kConnectionPragmas) {
      db.execute(pragma);
    }
    _migrate(db, path, migrations);
    return db;
  } on Object {
    db.dispose();
    rethrow;
  }
}

void _migrate(Database db, String path, List<Migration> migrations) {
  final int diskVersion = db.userVersion;
  final int supported = migrations.isEmpty ? 0 : migrations.last.toVersion;

  if (diskVersion > supported) {
    // 明确报错拒绝打开，不尝试兼容读取（存储设计 §9）。降级读新库可能
    // 静默丢掉新列里的数据，比打不开更糟。
    throw StorageError(
      '数据库版本高于当前应用支持的版本，拒绝打开。请升级应用。',
      context: <String, Object?>{
        'path': path,
        'diskVersion': diskVersion,
        'supportedVersion': supported,
      },
    );
  }

  for (final Migration m in migrations) {
    if (m.toVersion <= diskVersion) continue;

    db.execute('BEGIN');
    try {
      for (final String sql in m.statements) {
        db.execute(sql);
      }
      db.userVersion = m.toVersion;
      db.execute('COMMIT');
    } on Object catch (e) {
      db.execute('ROLLBACK');
      throw StorageError(
        '数据库迁移失败，已回滚。',
        context: <String, Object?>{
          'path': path,
          'fromVersion': diskVersion,
          'toVersion': m.toVersion,
          'cause': e.toString(),
        },
      );
    }
  }
}
