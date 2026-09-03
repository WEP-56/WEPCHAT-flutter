import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/platform/workspace_guard.dart';
import 'package:wepchat/storage/storage.dart';
import 'package:wepchat/tools/memory/memory_tools.dart';
import 'package:wepchat/tools/tool.dart';

void main() {
  late Directory dir;
  late WepStorage storage;
  late ToolContext context;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('wepchat_tool_memory_');
    final String dbPath = p.join(dir.path, 'test.db');
    final String blobRoot = p.join(dir.path, 'blobs');
    await Directory(blobRoot).create();
    storage = await WepStorage.open(dbPath: dbPath, blobRoot: blobRoot);

    context = ToolContext(
      sessionId: 'test-session',
      workspace: WorkspaceGuard(dir.path),
      token: CancellationToken.none,
      storage: storage,
    );
  });

  tearDown(() async {
    await storage.close();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  group('save_memory', () {
    const SaveMemoryTool tool = SaveMemoryTool();

    test('保存新记忆', () async {
      final ToolResult result = await tool.execute(
        <String, Object?>{
          'category': 'user_profile',
          'key': 'profession',
          'content': '前端开发工程师',
        },
        context,
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('记忆已保存'));

      final List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(1));
      expect(memories.first.category, equals('user_profile'));
      expect(memories.first.key, equals('profession'));
    });

    test('相同 category + key 时覆盖', () async {
      await tool.execute(
        <String, Object?>{
          'category': 'user_preference',
          'key': 'ui_style',
          'content': '简洁风格',
        },
        context,
      );

      await tool.execute(
        <String, Object?>{
          'category': 'user_preference',
          'key': 'ui_style',
          'content': '丰富视觉效果',
        },
        context,
      );

      final List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(1));
      expect(memories.first.summary, contains('丰富视觉效果'));
    });

    test('更新时保留原记忆 ID', () async {
      await tool.execute(
        <String, Object?>{
          'category': 'user_profile',
          'key': 'profession',
          'content': '前端开发工程师',
        },
        context,
      );
      final String id = (await storage.listMemories()).single.id;

      await tool.execute(
        <String, Object?>{
          'category': 'user_profile',
          'key': 'profession',
          'content': '全栈开发工程师',
        },
        context,
      );

      final List<MemorySummary> memories = await storage.listMemories();
      expect(memories.single.id, id);
      expect(memories.single.summary, contains('全栈开发工程师'));
    });

    test('拒绝无效 category', () async {
      final ToolResult result = await tool.execute(
        <String, Object?>{
          'category': 'invalid',
          'key': 'test',
          'content': 'test',
        },
        context,
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('category 必须是'));
    });

    test('拒绝超长 content', () async {
      final ToolResult result = await tool.execute(
        <String, Object?>{
          'category': 'user_profile',
          'key': 'test',
          'content': 'x' * 201,
        },
        context,
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('不能超过 200 字符'));
    });
  });

  group('list_memory', () {
    const ListMemoryTool tool = ListMemoryTool();

    test('列出所有记忆', () async {
      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'user_profile',
          key: 'profession',
          content: '开发',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem2',
          category: 'user_preference',
          key: 'style',
          content: '简洁',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final ToolResult result = await tool.execute(<String, Object?>{}, context);

      expect(result.isError, isFalse);
      expect(result.content, contains('共 2 条记忆'));
      expect(result.content, contains('user_profile'));
      expect(result.content, contains('user_preference'));
    });

    test('按 category 过滤', () async {
      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'user_profile',
          key: 'k1',
          content: 'c1',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      await storage.saveMemory(
        MemoryRecord(
          id: 'mem2',
          category: 'volatile',
          key: 'k2',
          content: 'c2',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final ToolResult result = await tool.execute(
        <String, Object?>{'category': 'user_profile'},
        context,
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('共 1 条记忆'));
      expect(result.content, contains('user_profile'));
      expect(result.content, isNot(contains('volatile')));
    });

    test('空记忆返回友好提示', () async {
      final ToolResult result = await tool.execute(<String, Object?>{}, context);

      expect(result.isError, isFalse);
      expect(result.content, contains('还没有记忆'));
    });
  });

  group('read_memory', () {
    const ReadMemoryTool tool = ReadMemoryTool();

    test('读取完整记忆', () async {
      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'user_profile',
          key: 'profession',
          content: '前端开发工程师，专注 React 和 Flutter',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      final ToolResult result = await tool.execute(
        <String, Object?>{'id': 'mem1'},
        context,
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('user_profile'));
      expect(result.content, contains('profession'));
      expect(result.content, contains('React 和 Flutter'));
    });

    test('不存在的记忆返回错误', () async {
      final ToolResult result = await tool.execute(
        <String, Object?>{'id': 'nonexistent'},
        context,
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('记忆不存在'));
    });
  });

  group('delete_memory', () {
    const DeleteMemoryTool tool = DeleteMemoryTool();

    test('删除记忆', () async {
      await storage.saveMemory(
        MemoryRecord(
          id: 'mem1',
          category: 'volatile',
          key: 'temp',
          content: '临时内容',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );

      List<MemorySummary> memories = await storage.listMemories();
      expect(memories.length, equals(1));

      final ToolResult result = await tool.execute(
        <String, Object?>{'id': 'mem1'},
        context,
      );

      expect(result.isError, isFalse);
      expect(result.content, contains('记忆已删除'));

      memories = await storage.listMemories();
      expect(memories.isEmpty, isTrue);
    });
  });
}
