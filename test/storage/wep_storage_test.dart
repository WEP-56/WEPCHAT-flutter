import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/core/errors.dart';
import 'package:wepchat/storage/storage.dart';

void main() {
  late Directory testRoot;
  late WepStorage storage;

  setUp(() async {
    testRoot = await Directory.systemTemp.createTemp('wepchat_test_');
    storage = await WepStorage.open(
      dbPath: p.join(testRoot.path, 'test.db'),
      blobRoot: p.join(testRoot.path, 'blobs'),
    );
  });

  tearDown(() async {
    await storage.close();
    if (testRoot.existsSync()) {
      testRoot.deleteSync(recursive: true);
    }
  });

  group('会话生命周期', () {
    test('创建并读回会话', () async {
      final SessionRecord session = await storage.createSession(
        title: '新会话',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );

      expect(session.id, isNotEmpty);
      expect(session.title, equals('新会话'));
      expect(session.isEmpty, isTrue);

      final SessionRecord? found = await storage.findSession(session.id);
      expect(found, isNotNull);
      expect(found!.id, equals(session.id));
      expect(found.title, equals('新会话'));
    });

    test('会话列表按时间倒序', () async {
      final SessionRecord s1 = await storage.createSession(
        title: '第一个',
        workspaceRoot: '/tmp/w1',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final SessionRecord s2 = await storage.createSession(
        title: '第二个',
        workspaceRoot: '/tmp/w2',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );

      final List<SessionSummary> summaries = await storage.listSessions();
      expect(summaries.length, equals(2));
      // 第二个更新时间晚，应该排在前面
      expect(summaries[0].id, equals(s2.id));
      expect(summaries[1].id, equals(s1.id));
    });

    test('改标题', () async {
      final SessionRecord session = await storage.createSession(
        title: '初始标题',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );

      await storage.renameSession(session.id, '改后标题');

      final SessionRecord? found = await storage.findSession(session.id);
      expect(found!.title, equals('改后标题'));
    });

    test('删除会话', () async {
      final SessionRecord session = await storage.createSession(
        title: '待删',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );

      await storage.deleteSession(session.id);

      final SessionRecord? found = await storage.findSession(session.id);
      expect(found, isNull);

      final List<SessionSummary> summaries = await storage.listSessions();
      expect(summaries, isEmpty);
    });
  });

  group('条目读写', () {
    late SessionRecord session;

    setUp(() async {
      session = await storage.createSession(
        title: '测试会话',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );
    });

    test('追加用户消息', () async {
      final int seq = await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-user-1',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': 'Hello'},
        ),
        preview: 'Hello',
        contextTokens: 100,
      );

      expect(seq, equals(1));

      final List<EntryRecord> entries = await storage.readContext(session.id);
      expect(entries.length, equals(1));
      expect(entries[0].seq, equals(1));
      expect(entries[0].type, equals(EntryType.message));
      expect(entries[0].role, equals(EntryRole.user));
      expect(entries[0].payload['text'], equals('Hello'));
    });

    test('追加助手消息', () async {
      await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-user-1',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': 'Hello'},
        ),
      );

      final int seq = await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-assistant-1',
          type: EntryType.message,
          role: EntryRole.assistant,
          stopReason: StopReason.stop,
          usage: const TokenUsage(
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 80,
            cost: 0.001,
          ),
          payload: <String, Object?>{'text': 'Hi there'},
        ),
        preview: 'Hi there',
        contextTokens: 150,
        costDelta: 0.001,
      );

      expect(seq, equals(2));

      final List<EntryRecord> entries = await storage.readContext(session.id);
      expect(entries.length, equals(2));
      expect(entries[1].stopReason, equals(StopReason.stop));
      expect(entries[1].usage.inputTokens, equals(100));
      expect(entries[1].usage.cacheReadTokens, equals(80));
    });

    test('seq 单调递增', () async {
      final int seq1 = await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-1',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': 'A'},
        ),
      );

      final int seq2 = await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-2',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': 'B'},
        ),
      );

      expect(seq2, equals(seq1 + 1));
    });

    test('readTail 倒序分页', () async {
      // 追加 5 条
      for (int i = 0; i < 5; i++) {
        await storage.appendEntry(
          session.id,
          NewEntry(
            id: 'ulid-$i',
            type: EntryType.message,
            role: EntryRole.user,
            payload: <String, Object?>{'text': 'Message $i'},
          ),
        );
      }

      // 取最新 3 条
      final List<EntryRecord> tail = await storage.readTail(
        session.id,
        limit: 3,
      );
      expect(tail.length, equals(3));
      // 按 seq 升序返回
      expect(tail[0].seq, equals(3));
      expect(tail[1].seq, equals(4));
      expect(tail[2].seq, equals(5));

      // 翻页取前面的
      final List<EntryRecord> prev = await storage.readTail(
        session.id,
        limit: 3,
        beforeSeq: tail[0].seq,
      );
      expect(prev.length, equals(2));
      expect(prev[0].seq, equals(1));
      expect(prev[1].seq, equals(2));
    });
  });

  group('payload 编码', () {
    late SessionRecord session;

    setUp(() async {
      session = await storage.createSession(
        title: '编码测试',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );
    });

    test('小 payload 走 json', () async {
      await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-small',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': 'Short message'},
        ),
      );

      final List<EntryRecord> entries = await storage.readContext(session.id);
      expect(entries[0].payload['text'], equals('Short message'));
    });

    test('大 payload 走 gzip 或 external（间接验证）', () async {
      // 构造一个 5KB 的 payload，超过 4KB 阈值
      final String longText = 'A' * 5000;
      await storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-large',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': longText},
        ),
      );

      final List<EntryRecord> entries = await storage.readContext(session.id);
      expect(entries[0].payload['text'], equals(longText));
    });
  });

  group('派生状态', () {
    late SessionRecord session;

    setUp(() async {
      session = await storage.createSession(
        title: '派生状态测试',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
        thinking: ThinkingLevel.off,
      );
    });

    test('切换模型', () async {
      final int seq = await storage.changeModel(
        session.id,
        providerId: 'openai',
        modelId: 'gpt-4',
      );

      expect(seq, equals(1));

      final SessionRecord? updated = await storage.findSession(session.id);
      expect(updated!.providerId, equals('openai'));
      expect(updated.modelId, equals('gpt-4'));

      // 验证 *_change 条目存在
      final List<EntryRecord> changes =
          await storage.readStateChanges(session.id);
      expect(changes.length, equals(1));
      expect(changes[0].type, equals(EntryType.modelChange));
      expect(changes[0].payload['providerId'], equals('openai'));
      expect(changes[0].payload['modelId'], equals('gpt-4'));
    });

    test('切换思考档位', () async {
      final int seq = await storage.changeThinking(
        session.id,
        ThinkingLevel.high,
      );

      expect(seq, equals(1));

      final SessionRecord? updated = await storage.findSession(session.id);
      expect(updated!.thinking, equals(ThinkingLevel.high));

      final List<EntryRecord> changes =
          await storage.readStateChanges(session.id);
      expect(changes.length, equals(1));
      expect(changes[0].type, equals(EntryType.thinkingChange));
      expect(changes[0].payload['thinking'], equals('high'));
    });
  });

  group('run 标记', () {
    late SessionRecord session;

    setUp(() async {
      session = await storage.createSession(
        title: 'run 测试',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );
    });

    test('开始并完成 run', () async {
      final String runId = await storage.startRun(session.id);
      expect(runId, isNotEmpty);

      await storage.finishRun(runId, RunOutcome.completed);
      // 没抛错就算通过
    });

    test('启动时标记中断', () async {
      // 新开一个存储实例模拟重启
      await storage.close();

      final Directory testRoot2 = await Directory.systemTemp.createTemp(
        'wepchat_test_interrupted_',
      );
      addTearDown(() {
        if (testRoot2.existsSync()) {
          testRoot2.deleteSync(recursive: true);
        }
      });

      final WepStorage storage2 = await WepStorage.open(
        dbPath: p.join(testRoot2.path, 'test.db'),
        blobRoot: p.join(testRoot2.path, 'blobs'),
      );
      addTearDown(() async => storage2.close());

      final SessionRecord s = await storage2.createSession(
        title: '中断测试',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );

      // 故意不 finish，直接关闭——重开时应该被标成中断
      await storage2.startRun(s.id);
      await storage2.close();

      // 再开，应该会标记中断
      final WepStorage storage3 = await WepStorage.open(
        dbPath: p.join(testRoot2.path, 'test.db'),
        blobRoot: p.join(testRoot2.path, 'blobs'),
      );
      addTearDown(() async => storage3.close());

      final List<String> interrupted =
          await storage3.reconcileInterruptedRuns();
      expect(interrupted, contains(s.id));
    });
  });

  group('blob GC', () {
    test('空库 GC 无内容', () async {
      final BlobGcResult result = await storage.collectBlobGarbage();
      expect(result.isEmpty, isTrue);
    });
  });

  group('会话压缩', () {
    late SessionRecord session;

    setUp(() async {
      session = await storage.createSession(
        title: '压缩测试',
        workspaceRoot: '/tmp/workspace',
        providerId: 'anthropic',
        modelId: 'claude-opus-5',
      );
    });

    Future<int> appendMessage(String text) {
      return storage.appendEntry(
        session.id,
        NewEntry(
          id: 'ulid-$text',
          type: EntryType.message,
          role: EntryRole.user,
          payload: <String, Object?>{'text': text},
        ),
      );
    }

    test('压缩后上下文只剩摘要，原始条目仍在库里', () async {
      await appendMessage('一');
      await appendMessage('二');
      final int last = await appendMessage('三');

      final int baseSeq = await storage.compressSession(
        session.id,
        summary: '用户数了三个数',
        replacedThrough: last,
        tokenEst: 12,
      );

      expect(baseSeq, equals(4));

      // 上下文起点已移到摘要，前三条不再参与组装。
      final List<EntryRecord> context = await storage.readContext(session.id);
      expect(context.length, equals(1));
      expect(context.single.type, equals(EntryType.compaction));
      expect(context.single.payload['summary'], equals('用户数了三个数'));
      expect(context.single.tokenEst, equals(12));

      // 但原始条目一条都没删——readTail 不看 base_seq，能证明它们还在。
      final List<EntryRecord> all = await storage.readTail(session.id);
      expect(all.length, equals(4));
      expect(all.first.payload['text'], equals('一'));
    });

    test('压缩后新消息接在摘要之后进上下文', () async {
      final int last = await appendMessage('旧话');
      await storage.compressSession(
        session.id,
        summary: '聊过旧话',
        replacedThrough: last,
      );
      await appendMessage('新话');

      final List<EntryRecord> context = await storage.readContext(session.id);
      expect(context.length, equals(2));
      expect(context[0].type, equals(EntryType.compaction));
      expect(context[1].payload['text'], equals('新话'));
    });

    test('可以连续压缩，起点只前进', () async {
      final int first = await appendMessage('一');
      final int firstBase = await storage.compressSession(
        session.id,
        summary: '摘要一',
        replacedThrough: first,
      );

      final int second = await appendMessage('二');
      final int secondBase = await storage.compressSession(
        session.id,
        summary: '摘要二',
        replacedThrough: second,
      );

      expect(secondBase, greaterThan(firstBase));

      // 第二次压缩把第一条摘要也盖掉了，上下文只剩最新那条。
      final List<EntryRecord> context = await storage.readContext(session.id);
      expect(context.length, equals(1));
      expect(context.single.payload['summary'], equals('摘要二'));
    });

    test('会话不存在时报错', () async {
      expect(
        () => storage.compressSession(
          'no-such-session',
          summary: '摘要',
          replacedThrough: 1,
        ),
        throwsA(isA<StorageError>()),
      );
    });
  });
}
