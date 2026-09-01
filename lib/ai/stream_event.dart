/// 适配器吐出的流事件（实施 TODO §4-3）。
///
/// 序列固定：`start` → `textDelta` / `thinkingDelta` / `toolCallDelta`
/// （任意交错）→ `done`。
///
/// 每个事件都带**当前完整的 partial [message]**，不只是增量。界面可以
/// 直接整条重绘，不用自己拼——自己拼增量是 bug 的温床（丢事件、乱序、
/// 重复渲染都会表现成文字错乱，而且很难复现）。
///
/// 增量字段（[textDelta] 等）仍然给出来，供需要"逐字打字机效果"的地方用。
library;

import 'messages.dart';

sealed class StreamEvent {
  const StreamEvent({required this.message});

  /// 到此刻为止的完整消息。
  final ChatMessageModel message;
}

/// 流开始。此时 [message] 通常是空的 assistant 消息。
class StreamStart extends StreamEvent {
  const StreamStart({required super.message});
}

/// 正文增量。
class StreamTextDelta extends StreamEvent {
  const StreamTextDelta({required super.message, required this.delta});

  final String delta;
}

/// 思考增量。
class StreamThinkingDelta extends StreamEvent {
  const StreamThinkingDelta({required super.message, required this.delta});

  final String delta;
}

/// 工具调用参数正在累积。
///
/// 这个事件只用来驱动"正在调用 xxx 工具"的界面提示。参数在流结束前
/// 是**不完整的 JSON 字符串**，中途 parse 一定失败（§4-7），所以这里
/// 不给解析后的 Map，只给工具名和原始增量。
class StreamToolCallDelta extends StreamEvent {
  const StreamToolCallDelta({
    required super.message,
    required this.callId,
    required this.toolName,
    required this.argumentsDelta,
  });

  final String callId;
  final String toolName;
  final String argumentsDelta;
}

/// 流结束。[message] 是最终消息，带 `stopReason` 与 `usage`。
///
/// 失败也走这里：`stopReason` 为 `error` / `aborted`，`errorMessage` 带
/// 说明（§4-2）。上层 loop 因此只有一条失败路径要处理。
class StreamDone extends StreamEvent {
  const StreamDone({required super.message});

  StopReason get stopReason => message.stopReason ?? StopReason.stop;
  bool get isError => stopReason == StopReason.error;
  bool get isAborted => stopReason == StopReason.aborted;
}
