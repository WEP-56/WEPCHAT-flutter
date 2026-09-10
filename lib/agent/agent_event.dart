/// agent loop 对外吐出的事件（实施 TODO §5-2）。
///
/// 和 `StreamEvent`（`lib/ai/stream_event.dart`）的分工：那边是**一次 API
/// 调用**的事件，这边是**一整轮对话**的事件——包含若干次 API 调用和夹在
/// 中间的工具执行。界面订阅这一层，不直接订阅适配器。
library;

import '../ai/messages.dart';
import '../tools/tool.dart';

sealed class AgentEvent {
  const AgentEvent();
}

/// 一次 API 调用开始。[iteration] 从 1 起，用于界面显示"第 n 轮"。
class AgentTurnStart extends AgentEvent {
  const AgentTurnStart({required this.iteration});

  final int iteration;
}

class AgentStarted extends AgentEvent {
  const AgentStarted();
}

class AgentEnded extends AgentEvent {
  const AgentEnded({required this.stopReason});
  final StopReason stopReason;
}

/// assistant 消息有更新（正文或思考的增量）。
///
/// [message] 是当前完整的 partial 消息，界面整条重绘即可。
class AgentMessageUpdate extends AgentEvent {
  const AgentMessageUpdate({required this.message, this.textDelta});

  final ChatMessageModel message;

  /// 本次的正文增量，供打字机效果用；思考增量时为 null。
  final String? textDelta;
}

/// assistant 消息定稿（本次 API 调用结束）。
///
/// 拆出 start / update / end 三个事件是对协议 §10.3 的偏离（那边只有
/// `message_update`）：界面需要知道"这条完了"才能收起光标、落库、
/// 显示 usage，靠 update 事件自己猜等于把状态机放到界面里。
class AgentMessageEnd extends AgentEvent {
  const AgentMessageEnd({required this.message});

  final ChatMessageModel message;
}

/// 一条排队中的用户输入被并进上下文（排队式引导，协议 §10.4）。
///
/// 它出现的时刻是「上一批工具已经全部执行完、下一次请求还没发出」——
/// 用户在工具执行期间打的那句话到这时才交给模型，模型据此继续或重新规划，
/// 而不是在半途被打断（半途打断会让已经产生的副作用没有下文）。
///
/// 界面据此把「排队中」的气泡转成普通用户消息。
class AgentInputInjected extends AgentEvent {
  const AgentInputInjected({required this.message, required this.iteration});

  final ChatMessageModel message;

  /// 注入之后紧接着的那次 API 调用的序号。
  final int iteration;
}

/// 一个工具即将执行。
class AgentToolStart extends AgentEvent {
  const AgentToolStart({required this.call});

  final ToolCallPart call;
}

/// 一个工具执行完毕。
class AgentToolEnd extends AgentEvent {
  const AgentToolEnd({required this.call, required this.result});

  final ToolCallPart call;
  final ToolResult result;
}

/// 整轮结束。
///
/// [stopReason] 是最后一次 API 调用的停止原因；[hitMaxIterations] 为 true
/// 表示是撞上迭代上限被强制收尾的（§5-8），这和模型自然说完要区分开——
/// 前者意味着任务可能没做完。
class AgentDone extends AgentEvent {
  const AgentDone({
    required this.stopReason,
    required this.usage,
    this.hitMaxIterations = false,
    this.errorMessage,
  });

  final StopReason stopReason;

  /// 整轮累计用量（所有 API 调用之和）。
  final TokenUsage usage;

  final bool hitMaxIterations;
  final String? errorMessage;
}
