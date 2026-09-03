import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/storage/storage.dart';

void main() {
  late Directory dir;
  late WepStorage storage;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wepchat_memory_');
    final String dbPath = p.join(dir.path, 'test.db');
    final String blobRoot = p.join(dir.path, 'blobs');
    await Directory(blobRoot).create();
    storage = await WepStorage.open(dbPath: dbPath, blobRoot: blobRoot);
  });

  tearDown(() async {
    await storage.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('记忆 CRUD', () {
    test('保存并读取记忆', () async {
      final DateTime now = DateTime.now();
      final MemoryRecord memory = MemoryRecord(
        id: 'mem1',
        category: 'user_profile',
        key: 'profession',
        content: '前端开发工程师',
        createdAt: now,
        updatedAt: now,
      );

      await storage.saveMemory(memory);

      final MemoryRecord? read = await storage.readMemory('mem1');
      expect(read, isNotNull);
      expect(read!.category, equals('user_profile'));
      expect(read.key, equals('profession'));
      expect(read.content, equals('前端开发工程师'));
    });

    test('相同 category + key 时覆盖旧值', () async {
      final DateTime now = DateTime.now();

      // 第一次保存
      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'user_preference',
          key: 'ui_style',
          content: '喜欢简洁风格',
          createdAt: now,
          updatedAt: now,
        ),
      );

      // 相同 category + key，不同 id
      await storage.saveMemory(
        MemoryRecord(
          id: 'mem2',
          category: 'user_preference',
          key: 'ui_style',
          content: '喜欢丰富视觉效果',
          createdAt: now,
          updatedAt: now.add(const Duration(hours: 1)),
        ),
      );

      // 应该只有一条，且是新的
      final List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(1));
      expect(memories.first.key, equals('ui_style'));
      expect(memories.first.summary, contains('丰富视觉效果'));
    });

    test('list_memory 返回摘要（前 100 字符）', () async {
      final DateTime now = DateTime.now();
      final String longContent = '这是一段很长的内容。' * 20; // 超过 100 字符

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'volatile',
          key: 'current_project',
          content: longContent,
          createdAt: now,
          updatedAt: now,
        ),
      );

      final List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(1));
      expect(memories.first.summary.length, lessThanOrEqualTo(100));
      expect(longContent, startsWith(memories.first.summary));
    });

    test('按 category 过滤', () async {
      final DateTime now = DateTime.now();

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'user_profile',
          key: 'profession',
          content: '开发',
          createdAt: now,
          updatedAt: now,
        ),
      );

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem2',
          category: 'user_preference',
          key: 'style',
          content: '简洁',
          createdAt: now,
          updatedAt: now,
        ),
      );

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem3',
          category: 'volatile',
          key: 'project',
          content: '项目 X',
          createdAt: now,
          updatedAt: now,
        ),
      );

      final List<MemorySummary> all = await storage.listMemories();
      expect(all.length, equals(3));

      final List<MemorySummary> profiles =
          await storage.listMemories(category: 'user_profile');
      expect(profiles.length, equals(1));
      expect(profiles.first.category, equals('user_profile'));

      final List<MemorySummary> preferences =
          await storage.listMemories(category: 'user_preference');
      expect(preferences.length, equals(1));
      expect(preferences.first.category, equals('user_preference'));

      final List<MemorySummary> volatiles =
          await storage.listMemories(category: 'volatile');
      expect(volatiles.length, equals(1));
      expect(volatiles.first.category, equals('volatile'));
    });

    test('删除记忆', () async {
      final DateTime now = DateTime.now();

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'volatile',
          key: 'temp',
          content: '临时内容',
          createdAt: now,
          updatedAt: now,
        ),
      );

      List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(1));

      await storage.deleteMemory('mem1');

      memories = await storage.listMemories();
      expect(memories.isEmpty, isTrue);

      final MemoryRecord? read = await storage.readMemory('mem1');
      expect(read, isNull);
    });

    test('按更新时间倒序排列', () async {
      final DateTime base = DateTime.now();

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'user_profile',
          key: 'k1',
          content: '第一个',
          createdAt: base,
          updatedAt: base,
        ),
      );

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem2',
          category: 'user_profile',
          key: 'k2',
          content: '第二个',
          createdAt: base.add(const Duration(minutes: 1)),
          updatedAt: base.add(const Duration(minutes: 1)),
        ),
      );

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem3',
          category: 'user_profile',
          key: 'k3',
          content: '第三个',
          createdAt: base.add(const Duration(minutes: 2)),
          updatedAt: base.add(const Duration(minutes: 2)),
        ),
      );

      final List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(3));
      expect(memories[0].key, equals('k3')); // 最新的在前
      expect(memories[1].key, equals('k2'));
      expect(memories[2].key, equals('k1'));
    });
  });
}
