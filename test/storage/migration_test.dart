import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:wepchat/core/errors.dart';
import 'package:wepchat/storage/migration.dart';
import 'package:wepchat/storage/schema.dart';

/// 一条假的 v2 迁移。
///
/// 用假的而不是等真的 v2 出现：要验的是迁移框架本身（挑出待办、写
/// user_version、失败回滚），这套逻辑不该等到下一次改结构才第一次被跑到。
const Migration _v2 = Migration(2, <String>[
  'ALTER TABLE sessions ADD COLUMN pinned INTEGER NOT NULL DEFAULT 0',
  'CREATE INDEX idx_sessions_pinned ON sessions(pinned)',
]);

const Migration _brokenV2 = Migration(2, <String>[
  'ALTER TABLE sessions ADD COLUMN ok INTEGER NOT NULL DEFAULT 0',
  'ALTER TABLE nonexistent_table ADD COLUMN boom INTEGER',
]);

void main() {
  late Directory dir;
  late String dbPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wepchat_migration_');
    dbPath = p.join(dir.path, 'test.db');
  });

  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  /// 打开、做点事、关掉——每个用例都要模拟"应用重启"，所以封一下。
  void withDb(
    void Function(Database db) body, {
    List<Migration> migrations = kMigrations,
  }) {
    final Database db = openAndMigrate(dbPath, migrations: migrations);
    try {
      body(db);
    } finally {
      db.dispose();
    }
  }

  /// 插一行 sessions。NOT NULL 的列都要给值，集中在这里，
  /// 免得每个用例各写一份 INSERT。
  void insertSession(
    Database db, {
    required String id,
    required String title,
    int headSeq = 0,
  }) {
    db.execute(
      'INSERT INTO sessions(id, title, created_at, updated_at, workspace_root, '
      'provider_id, model_id, thinking, head_seq, base_seq) '
      'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, 0)',
      <Object?>[
        id,
        title,
        1000,
        1000,
        '/ws/$id',
        'anthropic',
        'claude-sonnet-4',
        'off',
        headSeq,
      ],
    );
  }

  List<String> columnsOf(Database db, String table) {
    return db
        .select('PRAGMA table_info($table)')
        .map((Row r) => r['name'] as String)
        .toList();
  }

  group('首次建库', () {
    test('空目录建出 v1，user_version 落到当前版本', () {
      withDb((Database db) {
        expect(db.userVersion, equals(kSchemaVersion));
        expect(columnsOf(db, 'sessions'), contains('head_seq'));
      });
    });

    test('重开已有库不重跑迁移，数据还在', () {
      withDb((Database db) {
        insertSession(db, id: 's1', title: '标题');
      });

      withDb((Database db) {
        final ResultSet rows = db.select('SELECT title FROM sessions');
        expect(rows.length, equals(1));
        expect(rows.first['title'], equals('标题'));
      });
    });
  });

  group('向前迁移', () {
    test('v1 库升到 v2：新列建出来，老数据不动', () {
      withDb((Database db) {
        insertSession(db, id: 's1', title: '升级前', headSeq: 3);
      });

      withDb((Database db) {
        expect(db.userVersion, equals(2));
        expect(columnsOf(db, 'sessions'), contains('pinned'));

        final Row row = db.select('SELECT * FROM sessions').first;
        expect(row['title'], equals('升级前'));
        expect(row['head_seq'], equals(3));
        expect(row['pinned'], equals(0));
      }, migrations: <Migration>[...kMigrations, _v2]);
    });

    test('已经是 v2 的库再开一次不重跑', () {
      final List<Migration> all = <Migration>[...kMigrations, _v2];

      withDb((Database _) {}, migrations: all);
      // 重跑会因为列already exists 报错，能开起来就说明跳过了。
      withDb(
        (Database db) => expect(db.userVersion, equals(2)),
        migrations: all,
      );
    });

    test('一次开库连跑多条待办迁移', () {
      withDb((Database db) {
        expect(db.userVersion, equals(2));
        expect(columnsOf(db, 'sessions'), contains('pinned'));
      }, migrations: <Migration>[...kMigrations, _v2]);
    });
  });

  group('失败处理', () {
    test('迁移中途失败整条回滚，版本号不动', () {
      withDb((Database _) {});

      expect(
        () => openAndMigrate(
          dbPath,
          migrations: <Migration>[...kMigrations, _brokenV2],
        ),
        throwsA(isA<StorageError>()),
      );

      // 版本停在 1，失败那条里成功的第一句也没留下——否则下次升级会
      // 撞上"列已存在"，库就永远升不上去了。
      withDb((Database db) {
        expect(db.userVersion, equals(kSchemaVersion));
        expect(columnsOf(db, 'sessions'), isNot(contains('ok')));
      });
    });

    test('库版本高于代码支持版本时拒绝打开', () {
      withDb((Database _) {}, migrations: <Migration>[...kMigrations, _v2]);

      // 模拟降级：装过新版（v2），退回只认 v1 的旧版应用。
      StorageError? caught;
      try {
        openAndMigrate(dbPath, migrations: kMigrations).dispose();
      } on StorageError catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      final Map<String, Object?> ctx = caught!.context!;
      expect(ctx['diskVersion'], equals(2));
      expect(ctx['supportedVersion'], equals(kSchemaVersion));
    });

    test('拒绝打开时连接已经关掉，文件没被占住', () {
      withDb((Database _) {}, migrations: <Migration>[...kMigrations, _v2]);

      expect(
        () => openAndMigrate(dbPath, migrations: kMigrations),
        throwsA(isA<StorageError>()),
      );

      // Windows 上句柄没松开的话这里会 errno 32。
      File(dbPath).deleteSync();
      expect(File(dbPath).existsSync(), isFalse);
    });
  });
}
