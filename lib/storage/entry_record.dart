import 'models.dart';

/// `entries` 表的一行，payload 已解码（存储设计 §5.2）。
///
/// **条目一旦写入就不可变**。回填、修正、重新格式化、为了"整理"而合并或
/// 重排，全部禁止——prompt cache 按请求前缀逐字节匹配，动过的历史会让
/// 那一点之后的缓存全部失效（存储设计 §7.1）。
class EntryRecord {
  const EntryRecord({
    required this.sessionId,
    required this.seq,
    required this.id,
    required this.type,
    required this.createdAt,
    required this.payload,
    this.role,
    this.tokenEst = 0,
    this.stopReason,
    this.usage = const TokenUsage(),
  });

  final String sessionId;

  /// 会话内单调递增，从 1 起。不是全库自增——那会让会话内跳号。
  final int seq;

  /// ULID，跨会话唯一。
  final String id;

  final EntryType type;

  /// 仅 [EntryType.message] 时非空。
  final EntryRole? role;

  final DateTime createdAt;

  /// token 估算值。提成列供压缩阈值判断，不必反序列化 payload。
  final int tokenEst;

  /// 仅 assistant 消息非空。
  final StopReason? stopReason;

  final TokenUsage usage;

  /// 消息本体。结构由 `type` 决定，存储层不解释内容。
  final Map<String, Object?> payload;

  bool get isMessage => type == EntryType.message;

  /// 这条条目是否应进入发给模型的上下文。
  ///
  /// 出错或被中断的 assistant 轮次不进上下文（实施 TODO §6-14），
  /// 判断只看 [stopReason] 列，不解析 payload。
  bool get isUsableInContext {
    final StopReason? reason = stopReason;
    if (reason == null) return true;
    return reason.isUsable;
  }

  @override
  String toString() =>
      'EntryRecord($sessionId#$seq, ${type.wire}'
      '${role == null ? '' : '/${role!.wire}'})';
}

/// 待写入的条目。没有 [EntryRecord.seq]——取号在事务内完成
/// （存储设计 §5.2），调用方不能自己指定，否则并发写会撞号。
class NewEntry {
  const NewEntry({
    required this.id,
    required this.type,
    required this.payload,
    this.role,
    this.tokenEst = 0,
    this.stopReason,
    this.usage = const TokenUsage(),
    this.createdAt,
  });

  final String id;
  final EntryType type;
  final EntryRole? role;
  final int tokenEst;
  final StopReason? stopReason;
  final TokenUsage usage;
  final Map<String, Object?> payload;

  /// 留空则用写入时刻。显式传入仅用于测试。
  final DateTime? createdAt;
}
