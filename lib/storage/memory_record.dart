/// 全局记忆条目（功能协议 §7）。
///
/// 不属于任何单个会话工作区，由 App 私有存储维护。记忆是 LLM 的工作笔记本，
/// 分三个区域：用户画像、用户倾向、波动区域。
library;

/// 记忆条目，纯 Dart 模型。
class MemoryRecord {
  const MemoryRecord({
    required this.id,
    required this.category,
    required this.key,
    required this.content,
    this.tags,
    required this.createdAt,
    required this.updatedAt,
  });

  /// 稳定主键，ULID。
  final String id;

  /// 三层结构之一：user_profile / user_preference / volatile
  final String category;

  /// 更新键，相同 category + key 时覆盖旧值。
  final String key;

  /// 记忆正文，用户可见可编辑的部分。
  final String content;

  /// 可选结构化标签，JSON 字符串。
  final String? tags;

  final DateTime createdAt;
  final DateTime updatedAt;

  MemoryRecord copyWith({
    String? id,
    String? category,
    String? key,
    String? content,
    String? tags,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return MemoryRecord(
      id: id ?? this.id,
      category: category ?? this.category,
      key: key ?? this.key,
      content: content ?? this.content,
      tags: tags ?? this.tags,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

/// list_memory 返回的摘要，不含完整 content。
class MemorySummary {
  const MemorySummary({
    required this.id,
    required this.category,
    required this.key,
    required this.summary,
    required this.updatedAt,
  });

  final String id;
  final String category;
  final String key;

  /// 前 100 字符的摘要。
  final String summary;

  final DateTime updatedAt;
}
