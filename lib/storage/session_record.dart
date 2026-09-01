import 'models.dart';

/// `sessions` 表的一行（存储设计 §5.1）。
///
/// [providerId] / [modelId] / [thinking] 是**派生状态的缓存**。权威值靠
/// `model_change` / `thinking_change` 条目回放得到（存储设计 §7.3）；
/// 两者不一致时以回放为准，并当作 bug 报错，不静默采用缓存值。
class SessionRecord {
  const SessionRecord({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.workspaceRoot,
    required this.providerId,
    required this.modelId,
    required this.thinking,
    required this.preview,
    required this.headSeq,
    required this.baseSeq,
    required this.contextTokens,
    required this.costTotal,
    this.deletedAt,
  });

  /// ULID，同时是工作区目录名（功能协议 §2.1）。
  final String id;

  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 创建时的工作区根目录。设置改动不迁移旧会话（功能协议 §2.1）。
  final String workspaceRoot;

  final String providerId;
  final String modelId;
  final ThinkingLevel thinking;

  /// 会话列表的预览文本，避免为了一行摘要去读 payload。
  final String preview;

  /// 最后一条条目的 `seq`。取号靠它自增。
  final int headSeq;

  /// 上下文起点。压缩后指向最新的 compaction 条目（存储设计 §7.2）。
  final int baseSeq;

  final int contextTokens;
  final double costTotal;

  /// 软删除时间。非空表示已删除，用于与工作区目录对账清理。
  final DateTime? deletedAt;

  bool get isDeleted => deletedAt != null;

  /// 是否还没有任何条目。
  bool get isEmpty => headSeq == 0;

  SessionRecord copyWith({
    String? title,
    DateTime? updatedAt,
    String? providerId,
    String? modelId,
    ThinkingLevel? thinking,
    String? preview,
    int? headSeq,
    int? baseSeq,
    int? contextTokens,
    double? costTotal,
  }) {
    return SessionRecord(
      id: id,
      title: title ?? this.title,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      workspaceRoot: workspaceRoot,
      providerId: providerId ?? this.providerId,
      modelId: modelId ?? this.modelId,
      thinking: thinking ?? this.thinking,
      preview: preview ?? this.preview,
      headSeq: headSeq ?? this.headSeq,
      baseSeq: baseSeq ?? this.baseSeq,
      contextTokens: contextTokens ?? this.contextTokens,
      costTotal: costTotal ?? this.costTotal,
      deletedAt: deletedAt,
    );
  }

  @override
  String toString() =>
      'SessionRecord($id, title=$title, head=$headSeq, base=$baseSeq)';
}

/// 会话列表用的轻量投影（存储设计 §1 的第三种读法）。
///
/// 会话列表每次启动都要查，但**不需要正文**。单独一个类型是为了让
/// "列表查询不读 payload" 这件事在类型上可见，而不是靠调用方自觉。
class SessionSummary {
  const SessionSummary({
    required this.id,
    required this.title,
    required this.updatedAt,
    required this.preview,
    required this.modelId,
    required this.contextTokens,
    required this.costTotal,
  });

  final String id;
  final String title;
  final DateTime updatedAt;
  final String preview;
  final String modelId;
  final int contextTokens;
  final double costTotal;

  @override
  String toString() => 'SessionSummary($id, $title)';
}
