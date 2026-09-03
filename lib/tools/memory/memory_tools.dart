/// 全局记忆工具：`save_memory`、`list_memory`、`read_memory`、`delete_memory`。
///
/// 记忆是 LLM 的工作笔记本，分三层：用户画像、用户倾向、波动区域（功能协议 §7）。
library;

import '../../ai/provider_api.dart';
import '../../core/ulid.dart';
import '../../storage/storage.dart';
import '../tool.dart';

/// `save_memory`：新增或更新一条记忆。
///
/// 相同 `category + key` 时覆盖旧值，否则新增。
class SaveMemoryTool extends Tool {
  const SaveMemoryTool();

  @override
  String get permissionId => 'memory';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'save_memory',
    description:
        '保存或更新一条跨会话全局记忆。仅在以下情况调用：\n'
        '1. 用户明确要求“记住”或“保存”；\n'
        '2. 用户明确表达稳定的身份、职业、技术背景或长期约束；\n'
        '3. 用户明确表达长期有效的风格、技术或交互偏好；\n'
        '4. 对后续工作有用的项目状态、目标或约束，并且 content 包含明确的过期条件。\n\n'
        '分类：user_profile 是稳定事实；user_preference 是长期偏好；volatile 是短期状态。\n'
        '不要保存一次性任务细节、普通闲聊、助手推测、未经确认的敏感信息，或密码、API Key、访问令牌等秘密。\n'
        '保存前先用 list_memory 检查已有条目；相同 category + key 表示更新，不要创建重复条目。\n'
        '每条 content 不超过 200 字符并聚焦核心信息；volatile 必须写明过期条件。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'category': <String, Object?>{
          'type': 'string',
          'enum': <String>['user_profile', 'user_preference', 'volatile'],
          'description':
              '记忆分类：user_profile（稳定事实） / user_preference（偏好模式） / volatile（短期状态）',
        },
        'key': <String, Object?>{
          'type': 'string',
          'description':
              '记忆键，简短的英文标识符（如 profession, ui_style, project_x）。同一 category 下相同 key 会覆盖旧值。',
        },
        'content': <String, Object?>{
          'type': 'string',
          'description': '记忆内容，200 字符以内。volatile 必须包含过期条件（如"X 完成后删除"）。',
        },
      },
      'required': <String>['category', 'key', 'content'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final String? category = arguments['category'] as String?;
    final String? key = arguments['key'] as String?;
    final String? content = arguments['content'] as String?;

    if (category == null || category.isEmpty) {
      return ToolResult.error('缺少 category 参数');
    }
    if (key == null || key.isEmpty) {
      return ToolResult.error('缺少 key 参数');
    }
    if (content == null || content.isEmpty) {
      return ToolResult.error('缺少 content 参数');
    }

    if (!<String>[
      'user_profile',
      'user_preference',
      'volatile',
    ].contains(category)) {
      return ToolResult.error(
        'category 必须是 user_profile / user_preference / volatile 之一',
      );
    }

    if (content.length > 200) {
      return ToolResult.error(
        'content 不能超过 200 字符，当前 ${content.length} 字符。请精简核心信息。',
      );
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    final WepStorage? storage = context.storage;
    if (storage == null) {
      return ToolResult.error('存储未初始化');
    }

    final DateTime now = DateTime.now();
    final List<MemorySummary> summaries = await storage.listMemories(
      category: category,
    );
    MemorySummary? existingSummary;
    for (final MemorySummary summary in summaries) {
      if (summary.key == key) {
        existingSummary = summary;
        break;
      }
    }
    final MemoryRecord? existing = existingSummary == null
        ? null
        : await storage.readMemory(existingSummary.id);

    final MemoryRecord memory = MemoryRecord(
      id: existing?.id ?? Ulid.generate(),
      category: category,
      key: key,
      content: content,
      createdAt: existing?.createdAt ?? now,
      updatedAt: now,
    );

    try {
      await storage.saveMemory(memory);
      return ToolResult.ok(
        '记忆已保存：$category · $key',
        uiPayload: <String, Object?>{
          'type': 'memory_saved',
          'category': category,
          'key': key,
        },
      );
    } on Object catch (e) {
      return ToolResult.error('保存失败：$e');
    }
  }
}

/// `list_memory`：列出所有记忆的摘要（前 100 字符）。
class ListMemoryTool extends Tool {
  const ListMemoryTool();

  @override
  String get permissionId => 'memory';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'list_memory',
    description:
        '列出所有记忆的摘要。在每个新会话开始时调用，了解用户的背景和偏好。\n\n'
        '返回：前 100 字符摘要 + 元信息，按更新时间倒序。\n'
        '用途：\n'
        '• 新会话开始时：先 list_memory，再根据用户需求决定是否 read_memory 获取细节\n'
        '• 保存前检查：避免创建重复记忆，优先更新已有记忆\n'
        '• 维护清理：定期检查 volatile 区域，删除已过期的记忆',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'category': <String, Object?>{
          'type': 'string',
          'enum': <String>['user_profile', 'user_preference', 'volatile'],
          'description': '可选，只列出该分类的记忆',
        },
      },
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final String? category = arguments['category'] as String?;

    if (category != null &&
        !<String>[
          'user_profile',
          'user_preference',
          'volatile',
        ].contains(category)) {
      return ToolResult.error(
        'category 必须是 user_profile / user_preference / volatile 之一',
      );
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    final WepStorage? storage = context.storage;
    if (storage == null) {
      return ToolResult.error('存储未初始化');
    }

    try {
      final List<MemorySummary> memories = await storage.listMemories(
        category: category,
      );

      if (memories.isEmpty) {
        return ToolResult.ok(category == null ? '还没有记忆' : '$category 分类下还没有记忆');
      }

      final StringBuffer buf = StringBuffer();
      buf.writeln('共 ${memories.length} 条记忆：\n');
      for (final MemorySummary m in memories) {
        buf.writeln('ID: ${m.id}');
        buf.writeln('分类: ${m.category} · 键: ${m.key}');
        buf.writeln('摘要: ${m.summary}');
        buf.writeln('更新: ${m.updatedAt.toLocal()}');
        buf.writeln();
      }

      return ToolResult.ok(
        buf.toString(),
        uiPayload: <String, Object?>{
          'type': 'memory_list',
          'count': memories.length,
          'category': category,
        },
      );
    } on Object catch (e) {
      return ToolResult.error('列出记忆失败：$e');
    }
  }
}

/// `read_memory`：读取一条完整记忆。
class ReadMemoryTool extends Tool {
  const ReadMemoryTool();

  @override
  String get permissionId => 'memory';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'read_memory',
    description:
        '读取指定 ID 的完整记忆内容。'
        '先用 list_memory 获取 ID 列表，再用此工具读取完整内容。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'id': <String, Object?>{
          'type': 'string',
          'description': '记忆 ID，从 list_memory 获取',
        },
      },
      'required': <String>['id'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final String? id = arguments['id'] as String?;

    if (id == null || id.isEmpty) {
      return ToolResult.error('缺少 id 参数');
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    final WepStorage? storage = context.storage;
    if (storage == null) {
      return ToolResult.error('存储未初始化');
    }

    try {
      final MemoryRecord? memory = await storage.readMemory(id);

      if (memory == null) {
        return ToolResult.error('记忆不存在：$id');
      }

      final StringBuffer buf = StringBuffer();
      buf.writeln('分类: ${memory.category}');
      buf.writeln('键: ${memory.key}');
      buf.writeln('创建: ${memory.createdAt.toLocal()}');
      buf.writeln('更新: ${memory.updatedAt.toLocal()}');
      buf.writeln('\n内容:\n${memory.content}');

      return ToolResult.ok(buf.toString());
    } on Object catch (e) {
      return ToolResult.error('读取记忆失败：$e');
    }
  }
}

/// `delete_memory`：删除一条记忆。
class DeleteMemoryTool extends Tool {
  const DeleteMemoryTool();

  @override
  String get permissionId => 'memory';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'delete_memory',
    description:
        '删除一条全局记忆，用于维护你的记忆小本本。先用 list_memory 找到准确 ID。\n\n'
        '可以自主删除：\n'
        '• volatile 记忆已满足过期条件；\n'
        '• 记忆与已确认事实不符；\n'
        '• 记忆内容重复；\n'
        '• 记忆放在了错误分类中（例如把短期状态放入 user_profile）；\n'
        '• 用户明确要求忘记某项信息。\n\n'
        '不要因为信息暂时用不到就删除仍然有效的记忆。发现分类错误时，删除后如有必要用 save_memory 在正确分类保存修正版。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'id': <String, Object?>{'type': 'string', 'description': '要删除的记忆 ID'},
      },
      'required': <String>['id'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final String? id = arguments['id'] as String?;

    if (id == null || id.isEmpty) {
      return ToolResult.error('缺少 id 参数');
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    final WepStorage? storage = context.storage;
    if (storage == null) {
      return ToolResult.error('存储未初始化');
    }

    try {
      await storage.deleteMemory(id);
      return ToolResult.ok(
        '记忆已删除：$id',
        uiPayload: <String, Object?>{'type': 'memory_deleted', 'id': id},
      );
    } on Object catch (e) {
      return ToolResult.error('删除失败：$e');
    }
  }
}
