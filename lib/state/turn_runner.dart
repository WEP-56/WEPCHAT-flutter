/// 一轮 agent 对话的执行与落库（实施 TODO §5-3、§9-8）。
///
/// 从 `SessionStore` 拆出来：那边管会话列表和界面状态，这边管"消费
/// `AgentEvent`、按规矩落库、把进度画出来"。合在一起 `session_store.dart`
/// 会超过 800 行（AGENTS.md §2.1）。
///
/// 落盘时机是这个文件的核心，两条规矩不一样，都有理由（存储设计 §6.1）：
/// - 助手消息在 `message_end` 落盘。
/// - **工具结果每个执行完立刻落盘**——副作用已经发生了，进程被杀也不能丢。
library;

import '../agent/agent_event.dart';
import '../agent/agent_loop.dart';
import '../ai/messages.dart' as ai;
import '../core/cancellation_token.dart';
import '../core/ulid.dart';
import '../models/tool_call.dart';
import '../storage/storage.dart';
import '../tools/tool.dart';
import 'chat_turn.dart';
import 'tool_display.dart';

/// 一条正在生成的助手消息在界面上的样子。
///
/// 工具卡片和正文属于同一条气泡：模型先说"我看一下文件"，然后调工具，
/// 再接着说——中间插一条独立气泡会把一句话劈成两半。
class TurnDraft {
  const TurnDraft({
    required this.bubbleId,
    required this.text,
    required this.thinking,
    required this.tools,
  });

  /// 流式气泡的 id。整轮只生成一次：每帧换 id 会让 ListView 认为是新元素，
  /// 打字过程中整条消息会闪。
  final String bubbleId;

  final String text;
  final String thinking;
  final List<ToolCall> tools;
}

/// 一轮跑完的结果，供调用方决定 run 的收场。
class TurnResult {
  const TurnResult({required this.outcome, this.notice});

  final RunOutcome outcome;

  /// 要弹给用户的一次性提示；不需要则为 null。
  final String? notice;
}

/// 跑一轮，边跑边画边落库。
///
/// [paint] 每次界面需要更新时被调用，参数是当前完整的草稿——界面整条重绘
/// 即可，不必自己拼增量。
class TurnRunner {
  TurnRunner({
    required WepStorage storage,
    required String sessionId,
    required void Function(TurnDraft) paint,
  })  : _storage = storage,
        _sessionId = sessionId,
        _paint = paint;

  final WepStorage _storage;
  final String _sessionId;
  final void Function(TurnDraft) _paint;

  final String _bubbleId = Ulid.generate();
  final List<ToolCall> _cards = <ToolCall>[];
  final Map<String, DateTime> _startedAt = <String, DateTime>{};

  ai.ChatMessageModel? _lastAssistant;
  ai.TokenUsage _usage = const ai.TokenUsage();

  /// 消费整条事件流。
  ///
  /// loop 承诺不抛（§4-2、§5），所以这里没有 try/catch：真抛了说明 loop
  /// 有 bug，让它炸出来比在这里吞掉好——调用方那层还有一道兜底。
  Future<TurnResult> run(AgentLoop loop, List<ai.ChatMessageModel> history,
      CancellationToken token) async {
    ai.StopReason reason = ai.StopReason.stop;
    String? errorMessage;
    bool hitMaxIterations = false;

    await for (final AgentEvent event in loop.run(history, token)) {
      switch (event) {
        case AgentTurnStart():
          break;

        case AgentMessageUpdate(:final ai.ChatMessageModel message):
          _lastAssistant = message;
          _repaint(message);

        case AgentMessageEnd(:final ai.ChatMessageModel message):
          _lastAssistant = message;
          _usage = _usage + message.usage;
          // 助手消息在 message_end 落盘（§9-8）。空轮次不落：模型只调了
          // 工具没说话时，一条空气泡对用户毫无意义。
          await _persistAssistant(message);
          _repaint(message);

        case AgentToolStart(:final ai.ToolCallPart call):
          _startedAt[call.id] = DateTime.now();
          _cards.add(runningToolCall(call));
          _repaint(_lastAssistant);

        case AgentToolEnd(:final ai.ToolCallPart call, :final ToolResult result):
          await _finishTool(call, result);

        case AgentDone():
          reason = event.stopReason;
          errorMessage = event.errorMessage;
          hitMaxIterations = event.hitMaxIterations;
          _usage = event.usage;
      }
    }

    return _finish(reason, errorMessage, hitMaxIterations);
  }

  void _repaint(ai.ChatMessageModel? message) {
    _paint(
      TurnDraft(
        bubbleId: _bubbleId,
        text: message?.text ?? '',
        thinking: message?.thinkingText ?? '',
        tools: List<ToolCall>.unmodifiable(_cards),
      ),
    );
  }

  /// 工具结果立刻落盘，然后更新卡片（§9-8、存储设计 §6.1）。
  Future<void> _finishTool(ai.ToolCallPart call, ToolResult result) async {
    final DateTime? started = _startedAt.remove(call.id);
    final Duration? elapsed =
        started == null ? null : DateTime.now().difference(started);

    await _storage.appendEntry(
      _sessionId,
      NewEntry(
        id: Ulid.generate(),
        type: EntryType.message,
        role: EntryRole.toolResult,
        payload: <String, Object?>{
          'callId': call.id,
          'name': call.name,
          'arguments': call.arguments,
          'content': result.content,
          'outcome': result.outcome.name,
          if (result.uiPayload != null) 'ui': result.uiPayload,
        },
        tokenEst: result.content.length ~/ 4,
      ),
    );

    final int index = _cards.indexWhere((ToolCall c) => c.id == call.id);
    final ToolCall done = finishedToolCall(call, result, elapsed: elapsed);
    if (index < 0) {
      _cards.add(done);
    } else {
      _cards[index] = done;
    }
    _repaint(_lastAssistant);
  }

  Future<void> _persistAssistant(ai.ChatMessageModel message) async {
    final String text = message.text;
    final String thinking = message.thinkingText;

    // 只调工具没说话的轮次不落库：它没有给用户看的内容，而工具调用本身
    // 已经由 tool_result 条目记下了。
    if (text.isEmpty && thinking.isEmpty && message.errorMessage == null) {
      return;
    }

    final Map<String, Object?> payload = <String, Object?>{'text': text};
    if (thinking.isNotEmpty) payload['thinking'] = thinking;
    // 失败原因写进 payload 而不是丢掉：用户要看得见"为什么没回复"，
    // 而这条消息本身已经被 stopReason 挡在下次请求之外了。
    if (message.errorMessage != null) payload['error'] = message.errorMessage;

    await _storage.appendEntry(
      _sessionId,
      NewEntry(
        id: Ulid.generate(),
        type: EntryType.message,
        role: EntryRole.assistant,
        payload: payload,
        tokenEst: message.usage.outputTokens,
        stopReason: toStorageStopReason(
          message.stopReason ?? ai.StopReason.stop,
        ),
        usage: toStorageTokenUsage(message.usage),
      ),
      preview: text.isEmpty ? (message.errorMessage ?? '生成失败') : text,
    );
  }

  /// 收尾：把整轮的失败或中断状态补记下来。
  ///
  /// 助手消息已经在 `message_end` 落过了，这里只处理那之后才知道的事——
  /// loop 层面的失败（迭代上限、参数被截断、适配器没收尾）。
  Future<TurnResult> _finish(
    ai.StopReason reason,
    String? errorMessage,
    bool hitMaxIterations,
  ) async {
    // 一个字都没吐出来就被中断：不留空气泡，当这一轮没发生过。
    // 工具结果不受影响——它们已经各自落库了，副作用真的发生过。
    final bool silentAbort = reason == ai.StopReason.aborted &&
        (_lastAssistant?.text.trim().isEmpty ?? true);

    if (hitMaxIterations) {
      return TurnResult(
        outcome: RunOutcome.completed,
        notice: errorMessage ?? '达到迭代上限，已停止',
      );
    }

    return TurnResult(
      outcome: switch (reason) {
        ai.StopReason.error => RunOutcome.error,
        ai.StopReason.aborted => RunOutcome.aborted,
        ai.StopReason.stop ||
        ai.StopReason.toolUse ||
        ai.StopReason.length =>
          RunOutcome.completed,
      },
      // `length` 且有工具调用时 loop 会带 errorMessage 上来，用户得知道
      // 这一轮的工具没执行；silentAbort 是用户自己按的停止，不用再提示。
      notice: silentAbort ? null : errorMessage,
    );
  }

  /// 整轮累计用量（§10-5）。
  ai.TokenUsage get usage => _usage;
}
