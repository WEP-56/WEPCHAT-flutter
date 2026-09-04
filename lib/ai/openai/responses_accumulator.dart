/// openai-responses 流式响应的累积器（实施 TODO §4-8）。
///
/// 事件是**带 `type` 的具名 JSON**（`response.output_text.delta` 之类），
/// 不是 completions 的 choices/delta 结构，所以解析路径完全独立。
library;

import 'dart:convert';

import '../messages.dart';
import '../stream_event.dart';

/// 具名事件的累积器。
///
/// 事件序列（只列我们用到的）：
/// ```text
/// response.created
/// response.output_item.added        ← 新的输出项（消息 / function_call / reasoning）
/// response.output_text.delta        ← 正文增量
/// response.reasoning_summary_text.delta  ← 思考摘要增量
/// response.reasoning_text.delta          ← 部分兼容端点的思考增量
/// response.function_call_arguments.delta ← 工具参数字符串增量
/// response.output_item.done
/// response.completed | response.incomplete | response.failed
/// ```
/// 项与项之间靠 `output_index` 区分，同 anthropic 的 index 机制。
class ResponsesAccumulator {
  ResponsesAccumulator({required this.modelId});

  final String modelId;

  final StringBuffer _text = StringBuffer();
  final StringBuffer _thinking = StringBuffer();

  /// output_index → function_call 累积状态。
  final Map<int, _CallState> _calls = <int, _CallState>{};

  TokenUsage _usage = const TokenUsage();
  StopReason? _stopReason;
  String? _errorMessage;

  Stream<StreamEvent> consume(Map<String, Object?> event) async* {
    final String type = event['type'] as String? ?? '';

    switch (type) {
      case 'response.output_text.delta':
        final String chunk = event['delta'] as String? ?? '';
        if (chunk.isEmpty) return;
        _text.write(chunk);
        yield StreamTextDelta(message: snapshot(), delta: chunk);

      // 思考摘要/正文在不同 Responses 兼容端点上可能使用不同事件名；
      // 三种都接，因为端点版本由用户的 base url 决定，我们控制不了。
      case 'response.reasoning_summary_text.delta':
      case 'response.reasoning_summary.delta':
      case 'response.reasoning_text.delta':
        final String chunk = event['delta'] as String? ?? '';
        if (chunk.isEmpty) return;
        _thinking.write(chunk);
        yield StreamThinkingDelta(message: snapshot(), delta: chunk);

      case 'response.output_item.added':
        // function_call 项的 call_id 和 name 只在这里出现一次，
        // 后续的 arguments delta 事件里没有——必须在这里记下。
        final Object? item = event['item'];
        if (item is! Map<String, Object?>) return;
        if (item['type'] != 'function_call') return;

        final int index = _indexOf(event);
        _calls[index] = _CallState(
          id: item['call_id'] as String? ?? '',
          name: item['name'] as String? ?? '',
        );

      case 'response.function_call_arguments.delta':
        final int index = _indexOf(event);
        final _CallState? state = _calls[index];
        if (state == null) return; // 没见过 added 的 delta，跳过

        final String chunk = event['delta'] as String? ?? '';
        if (chunk.isEmpty) return;
        state.arguments.write(chunk);
        yield StreamToolCallDelta(
          message: snapshot(),
          callId: state.id,
          toolName: state.name,
          argumentsDelta: chunk,
        );

      case 'response.completed':
      case 'response.incomplete':
        _absorbResponse(event['response']);

      case 'response.failed':
        _absorbResponse(event['response']);
        _stopReason = StopReason.error;
        _errorMessage ??= '请求失败';

      case 'error':
        _stopReason = StopReason.error;
        _errorMessage = _errorTextOf(event);
    }
  }

  /// 终结事件里带完整的 response 对象：用量和结束原因都在这里。
  void _absorbResponse(Object? raw) {
    if (raw is! Map<String, Object?>) return;

    _usage = _mergeUsage(_usage, raw['usage']);

    // incomplete 时 status 是 incomplete，原因在 incomplete_details.reason。
    final Object? details = raw['incomplete_details'];
    if (details is Map<String, Object?>) {
      final String? reason = details['reason'] as String?;
      // max_output_tokens 必须映射成 length：工具参数可能被截断，
      // 整批不能执行（§5-9）。
      _stopReason = reason == 'max_output_tokens'
          ? StopReason.length
          : StopReason.error;
      _errorMessage ??= reason == 'content_filter' ? '内容被安全策略拦截' : null;
      return;
    }

    final Object? error = raw['error'];
    if (error != null) {
      _stopReason = StopReason.error;
      _errorMessage = _errorTextOf(<String, Object?>{'error': error});
      return;
    }

    // 正常完成：有工具调用就是 toolUse，否则是自然说完。
    // responses 端点没有等价于 finish_reason 的字段，只能这样判断。
    _stopReason = _calls.isEmpty ? StopReason.stop : StopReason.toolUse;
  }

  ChatMessageModel snapshot() {
    return ChatMessageModel(
      role: MessageRole.assistant,
      parts: _buildParts(),
      usage: _usage,
      modelId: modelId,
      stopReason: _stopReason,
      errorMessage: _errorMessage,
    );
  }

  ChatMessageModel finish(StopReason? forced) {
    if (forced != null) _stopReason = forced;
    _stopReason ??= _calls.isEmpty ? StopReason.stop : StopReason.toolUse;
    return snapshot();
  }

  ChatMessageModel fail(String message) {
    _stopReason = StopReason.error;
    _errorMessage = message;
    return snapshot();
  }

  List<ContentPart> _buildParts() {
    final List<ContentPart> parts = <ContentPart>[];

    final String thinking = _thinking.toString();
    if (thinking.isNotEmpty) {
      parts.add(ThinkingPart(thinking, modelId: modelId));
    }

    final String text = _text.toString();
    if (text.isNotEmpty) parts.add(TextPart(text));

    final List<int> indices = _calls.keys.toList()..sort();
    for (final int i in indices) {
      final _CallState state = _calls[i]!;
      parts.add(
        ToolCallPart(
          id: state.id,
          name: state.name,
          arguments: _tryParseArgs(state.arguments.toString()),
        ),
      );
    }

    return parts;
  }

  static int _indexOf(Map<String, Object?> event) =>
      (event['output_index'] as num?)?.toInt() ?? 0;

  static Map<String, Object?> _tryParseArgs(String raw) {
    if (raw.isEmpty) return const <String, Object?>{};
    try {
      final Object? decoded = jsonDecode(raw);
      return decoded is Map<String, Object?>
          ? decoded
          : const <String, Object?>{};
    } on FormatException {
      return const <String, Object?>{};
    }
  }

  static String _errorTextOf(Map<String, Object?> event) {
    final Object? error = event['error'];
    if (error is Map<String, Object?>) {
      final Object? message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    final Object? message = event['message'];
    if (message is String && message.isNotEmpty) return message;
    return '未知的 API 错误';
  }

  static TokenUsage _mergeUsage(TokenUsage current, Object? raw) {
    if (raw is! Map<String, Object?>) return current;

    int pick(String key, int fallback) =>
        (raw[key] as num?)?.toInt() ?? fallback;

    // 字段名和 completions 不同：input_tokens / output_tokens，
    // 不是 prompt_tokens / completion_tokens。
    int cacheRead = current.cacheReadTokens;
    final Object? inDetails = raw['input_tokens_details'];
    if (inDetails is Map<String, Object?>) {
      cacheRead = (inDetails['cached_tokens'] as num?)?.toInt() ?? cacheRead;
    }

    int reasoning = current.reasoningTokens;
    final Object? outDetails = raw['output_tokens_details'];
    if (outDetails is Map<String, Object?>) {
      reasoning =
          (outDetails['reasoning_tokens'] as num?)?.toInt() ?? reasoning;
    }

    return TokenUsage(
      inputTokens: pick('input_tokens', current.inputTokens),
      outputTokens: pick('output_tokens', current.outputTokens),
      cacheReadTokens: cacheRead,
      cacheWriteTokens: current.cacheWriteTokens,
      reasoningTokens: reasoning,
    );
  }
}

class _CallState {
  _CallState({required this.id, required this.name});

  final String id;
  final String name;
  final StringBuffer arguments = StringBuffer();
}
