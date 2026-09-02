import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/platform/workspace_paths.dart';
import 'package:wepchat/state/app_settings.dart';
import 'package:wepchat/state/session_store.dart';
import 'package:wepchat/storage/storage.dart';

/// `SessionStore` 的单元测试：状态机不变量。
///
/// 跨实例的持久化行为在 `test/integration/session_store_integration_test.dart`
/// 里覆盖，这里只管"一个实例内部的状态怎么变"。
///
/// 这里不会真的发出请求：`AppSettings.memory()` 的种子 provider 都没有 key，
/// 所以每次发送都停在"没配 key"的提示上，只留下用户那一条消息。想测真实
/// 流式生成得用假适配器，那是适配器自己的测试在做的事。
void main() {
  late Directory root;
  late WepStorage storage;
  late AppSettings settings;
  late SessionStore store;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wepchat_store_');
    storage = await WepStorage.open(
      dbPath: p.join(root.path, 'test.db'),
      blobRoot: p.join(root.path, 'blobs'),
    );
    settings = AppSettings.memory();
    store = await SessionStore.load(
      storage: storage,
      workspaces: WorkspaceRoots(p.join(root.path, 'workspaces')),
      settings: settings,
    );
  });

  tearDown(() async {
    store.dispose();
    settings.dispose();
    await storage.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('空库首启补一个会话，active 有值', () {
    expect(store.sessions.length, equals(1));
    expect(store.active.messages, isEmpty);
    expect(store.active.title, equals('新会话'));
  });

  test('发送消息后追加用户消息', () async {
    await store.sendMessage('帮我整理一下 Q2 销售数据');

    expect(store.active.messages.length, equals(1));
    expect(store.active.messages.single.isUser, isTrue);
    expect(store.isGenerating, isFalse);
  });

  test('没配 key 时用户消息照样落库，失败走一次性提示', () async {
    await store.sendMessage('你好');

    // 输入框那边已经清空了，把用户刚打的字丢掉是最糟的处理方式。
    expect(store.active.messages.length, equals(1));
    expect(store.takeNotice(), isNotNull);
    // 取过一次就没了，不会每次重绘都弹。
    expect(store.takeNotice(), isNull);
  });

  test('首条消息顺带改标题（功能协议 §2.1）', () async {
    await store.sendMessage('帮我写一个排序算法');

    expect(store.active.title, equals('帮我写一个排序算法'));
  });

  test('超长首句截断成标题', () async {
    await store.sendMessage('这是一句非常长的话超过了十六个字的上限所以要被截断');

    expect(store.active.title.length, equals(17)); // 16 字 + 省略号
    expect(store.active.title, endsWith('…'));
  });

  test('第二条消息不再改标题', () async {
    await store.sendMessage('第一句');
    await store.sendMessage('第二句');

    expect(store.active.title, equals('第一句'));
    expect(store.active.messages.length, equals(2));
  });

  test('空白消息被忽略', () async {
    await store.sendMessage('   ');

    expect(store.active.messages, isEmpty);
    expect(store.active.title, equals('新会话'));
  });

  test('新建会话插到列表头部并切过去', () async {
    final String firstId = store.activeId;
    await store.createSession(model: 'GPT-5');

    expect(store.sessions.length, equals(2));
    expect(store.sessions.first.id, equals(store.activeId));
    expect(store.activeId, isNot(equals(firstId)));
  });

  test('切换会话', () async {
    final String firstId = store.activeId;
    await store.createSession(model: 'GPT-5');

    store.select(firstId);

    expect(store.activeId, equals(firstId));
  });

  test('删除最后一个会话时补一个空会话，active 始终有值', () async {
    await store.deleteSession(
      store.activeId,
      fallbackModel: 'Claude Sonnet 4.5',
    );

    expect(store.sessions.length, equals(1));
    expect(store.active.messages, isEmpty);
  });

  test('删除当前会话后 active 落到剩下的第一个', () async {
    final String firstId = store.activeId;
    await store.createSession(model: 'GPT-5');
    final String secondId = store.activeId;

    await store.deleteSession(secondId, fallbackModel: 'Claude Sonnet 4.5');

    expect(store.sessions.length, equals(1));
    expect(store.activeId, equals(firstId));
  });

  test('改模型', () async {
    await store.setModel(store.activeId, 'GPT-5');

    expect(store.active.model, equals('GPT-5'));
  });

  test('空标题重命名被忽略', () async {
    await store.renameSession(store.activeId, '   ');

    expect(store.active.title, equals('新会话'));
  });

  test('操作不存在的会话会抛错，而不是静默忽略', () async {
    expect(() => store.select('nope'), throwsArgumentError);
    await expectLater(
      store.deleteSession('nope', fallbackModel: 'Claude Sonnet 4.5'),
      throwsArgumentError,
    );
  });

  test('每次改动都通知监听者', () async {
    int notifications = 0;
    store.addListener(() => notifications++);

    await store.sendMessage('你好');
    await store.createSession(model: 'GPT-5');
    await store.renameSession(store.activeId, '改名');

    expect(notifications, greaterThanOrEqualTo(3));
  });
}
