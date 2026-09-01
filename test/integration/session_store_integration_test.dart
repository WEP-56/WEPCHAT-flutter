import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/platform/workspace_paths.dart';
import 'package:wepchat/state/session_store.dart';
import 'package:wepchat/storage/storage.dart';

void main() {
  late Directory testRoot;
  late String dbPath;
  late String blobRoot;

  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('wepchat_integration_');
    dbPath = p.join(testRoot.path, 'test.db');
    blobRoot = p.join(testRoot.path, 'blobs');
  });

  tearDown(() {
    if (testRoot.existsSync()) {
      testRoot.deleteSync(recursive: true);
    }
  });

  /// 打开一个会话 store，执行闭包，关闭。
  Future<void> withStore(
    Future<void> Function(SessionStore store) block,
  ) async {
    final WepStorage storage = await WepStorage.open(
      dbPath: dbPath,
      blobRoot: blobRoot,
    );
    final SessionStore store = await SessionStore.load(
      storage: storage,
      workspaces: WorkspaceRoots(p.join(testRoot.path, 'workspaces')),
      defaultModel: 'Claude Sonnet 4.5',
    );
    try {
      await block(store);
    } finally {
      store.dispose();
      await storage.close();
    }
  }

  test('启动时自动创建默认会话', () async {
    await withStore((SessionStore store) async {
      expect(store.sessions.length, equals(1));
      expect(store.activeId, isNotEmpty);
      expect(store.active.title, equals('新会话'));
    });
  });

  test('发送消息并读回', () async {
    await withStore((SessionStore store) async {
      final String initialId = store.activeId;
      await store.sendMessage('Hello World');

      expect(store.active.title, equals('Hello World'));
      expect(store.active.messages.length, equals(1));
      expect(store.active.preview, equals('Hello World'));

      // 验证存储层已落盘
      final WepStorage storage2 = await WepStorage.open(
        dbPath: dbPath,
        blobRoot: blobRoot,
      );
      final SessionRecord? record = await storage2.findSession(initialId);
      await storage2.close();

      expect(record, isNotNull);
      expect(record!.preview, equals('Hello World'));
      expect(record.title, equals('Hello World'));
    });
  });

  test('创建并切换会话', () async {
    await withStore((SessionStore store) async {
      final int initialCount = store.sessions.length;
      await store.createSession(model: 'GPT-5');

      expect(store.sessions.length, equals(initialCount + 1));
      expect(store.active.title, equals('新会话'));
      expect(store.active.messages.isEmpty, isTrue);
    });
  });

  test('重命名会话', () async {
    await withStore((SessionStore store) async {
      final String sessionId = store.activeId;
      await store.renameSession(sessionId, '测试会话');

      expect(store.active.title, equals('测试会话'));
    });
  });

  test('删除会话后自动创建新会话', () async {
    await withStore((SessionStore store) async {
      final String sessionId = store.activeId;
      await store.deleteSession(sessionId, fallbackModel: 'Claude Sonnet 4.5');

      expect(store.sessions.length, equals(1));
      expect(store.activeId, isNot(equals(sessionId)));
    });
  });

  test('切换模型', () async {
    await withStore((SessionStore store) async {
      final String sessionId = store.activeId;
      await store.setModel(sessionId, 'GPT-5');

      expect(store.active.model, equals('GPT-5'));
    });
  });

  test('跨实例持久化：模拟应用重启', () async {
    String savedSessionId = '';
    const String testMessage = '这条消息要重启后还在';

    // 第一次启动：发消息
    await withStore((SessionStore store) async {
      savedSessionId = store.activeId;
      await store.sendMessage(testMessage);
      expect(store.active.messages.length, equals(1));
    });

    // 模拟应用重启：重新打开同一个库
    await withStore((SessionStore store) async {
      expect(store.sessions.length, equals(1));
      expect(store.activeId, equals(savedSessionId));
      expect(store.active.title, equals(testMessage));
      expect(store.active.messages.length, equals(1));
      expect(store.active.preview, equals(testMessage));
    });
  });

  test('多会话持久化', () async {
    // 第一次启动：建三个会话
    await withStore((SessionStore store) async {
      await store.sendMessage('第一个会话');
      await store.createSession(model: 'GPT-5');
      await store.sendMessage('第二个会话');
      await store.createSession(model: 'Gemini 2.5 Pro');
      await store.sendMessage('第三个会话');

      expect(store.sessions.length, equals(3));
    });

    // 重启后验证全在
    await withStore((SessionStore store) async {
      expect(store.sessions.length, equals(3));
      expect(store.sessions[0].title, equals('第三个会话'));
      expect(store.sessions[1].title, equals('第二个会话'));
      expect(store.sessions[2].title, equals('第一个会话'));
    });
  });
}
