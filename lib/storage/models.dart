/// 存储层领域模型（存储设计 §5）。
///
/// 这些类型是纯 Dart，不依赖 flutter，也不依赖 sqlite3 的类型
/// ——`Row` 不允许流出 DAO（AGENTS.md §8）。
library;

import '../core/errors.dart';

/// 条目类型。`entries.type` 列的取值。
enum EntryType {
  message('message'),
  compaction('compaction'),
  truncate('truncate'),
  modelChange('model_change'),
  thinkingChange('thinking_change'),
  toolsChange('tools_change');

  const EntryType(this.wire);

  final String wire;

  static EntryType fromWire(String wire) {
    for (final EntryType t in EntryType.values) {
      if (t.wire == wire) return t;
    }
    throw StorageError('未知的条目类型', context: <String, Object?>{'type': wire});
  }
}

/// 消息角色。`entries.role` 列的取值，仅 [EntryType.message] 时非空。
enum EntryRole {
  user('user'),
  assistant('assistant'),
  toolResult('tool_result');

  const EntryRole(this.wire);

  final String wire;

  static EntryRole fromWire(String wire) {
    for (final EntryRole r in EntryRole.values) {
      if (r.wire == wire) return r;
    }
    throw StorageError('未知的消息角色', context: <String, Object?>{'role': wire});
  }
}

/// 助手轮次的结束原因。`entries.stop_reason` 列。
///
/// 提成列而非留在 payload 里，因为"丢弃出错的 assistant 轮次"
/// （实施 TODO §6-14）要在不反序列化 payload 的前提下判断。
enum StopReason {
  stop('stop'),
  length('length'),
  toolUse('toolUse'),
  aborted('aborted'),
  error('error');

  const StopReason(this.wire);

  final String wire;

  static StopReason fromWire(String wire) {
    for (final StopReason s in StopReason.values) {
      if (s.wire == wire) return s;
    }
    throw StorageError(
      '未知的 stop reason',
      context: <String, Object?>{'stopReason': wire},
    );
  }

  /// 这一轮是否产出了可用于上下文的内容。
  ///
  /// aborted / error 的助手轮次在跨模型规范化时被丢弃
  /// （实施 TODO §6-14），token 估算也不把它当锚点（§6-17）。
  bool get isUsable => this != StopReason.aborted && this != StopReason.error;
}

/// 思考档位。`sessions.thinking` 列。
enum ThinkingLevel {
  /// 旧版本会话的兼容值。新建会话与界面不再提供关闭思考选项。
  off('off'),
  low('low'),
  medium('medium'),
  high('high'),
  xhigh('xhigh'),
  max('max');

  const ThinkingLevel(this.wire);

  final String wire;

  static ThinkingLevel fromWire(String wire) {
    for (final ThinkingLevel t in ThinkingLevel.values) {
      if (t.wire == wire) return t;
    }
    throw StorageError('未知的思考档位', context: <String, Object?>{'thinking': wire});
  }
}

/// 一次 run 的结局。`runs.outcome` 列（存储设计 §5.4）。
///
/// `finished_at IS NULL` 且进程重启过 ⇒ 上次被中断，启动时标为 [aborted]
/// 并让界面提示"可重试"。不实现自动续跑（存储设计 §6.2）。
enum RunOutcome {
  completed('completed'),
  aborted('aborted'),
  error('error');

  const RunOutcome(this.wire);

  final String wire;

  static RunOutcome fromWire(String wire) {
    for (final RunOutcome o in RunOutcome.values) {
      if (o.wire == wire) return o;
    }
    throw StorageError(
      '未知的 run outcome',
      context: <String, Object?>{'outcome': wire},
    );
  }
}

/// 一轮请求的 token 用量与费用。
///
/// `cacheRead` / `cacheWrite` 是缓存策略唯一的验证手段
/// （实施 TODO §6-12），必须一路带到界面。
class TokenUsage {
  const TokenUsage({
    this.inputTokens,
    this.outputTokens,
    this.cacheReadTokens,
    this.cacheWriteTokens,
    this.cost,
  });

  final int? inputTokens;
  final int? outputTokens;
  final int? cacheReadTokens;
  final int? cacheWriteTokens;
  final double? cost;

  /// 除费用外全空，说明这条条目不是模型响应。
  bool get isEmpty =>
      inputTokens == null &&
      outputTokens == null &&
      cacheReadTokens == null &&
      cacheWriteTokens == null;
}
