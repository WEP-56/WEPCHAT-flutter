/// openai-completions 流式响应的累积器（实施 TODO §4-7）。
///
/// 单独一个文件是因为 responses 适配器的解析路径完全独立（§4-8），
/// 两者除了共用 SSE 解析器之外没有可复用的部分——放一起会变成一个
/// 带两套 switch 的大文件。
library;

import 'dart:convert';

import '../messages.dart';
import '../model_compat.dart';
import '../stream_event.dart';

/// choices/delta 结构的累积器。
///
/// 三个坑（都来自真实端点）：
/// - `tool_calls` 的 `index` 是拼接依据，`id` 只在第一个 delta 出现
/// - `arguments` 是字符串增量，全部收完才是合法 JSON（中途 parse 一定失败）
/// - 思考内容有三种放法：`reasoning_content`（DeepSeek）/ `reasoning`
///   （部分兼容端点）/ `<think>` 标签（本地模型），按兼容标记选
class CompletionsAccumulator {
  CompletionsAccumulator({required this.modelId, required this.compat});

  final String modelId;
  final ModelCompat compat;

  final StringBuffer _text = StringBuffer();
  final StringBuffer _thinking = StringBuffer();

  /// index → tool call 累积状态。用 Map：服务端不保证 index 从 0 连续。
  final Map<int, _ToolCallState> _calls = <int, _ToolCallState>{};

  TokenUsage _usage = const TokenUsage();
  StopReason? _stopReason;
  String? _errorMessage;

  /// 消费一个 SSE 事件体。
  Stream<StreamEvent> consume(Map<String, Object?> event) async* {
    // 错误可以出现在 200 响应的流中间（限流、内容过滤、上游超时）。
    final Object? error = event['error'];
    if (error != null) {
      _errorMessage = _errorTextOf(error);
      _stopReason = StopReason.error;
      return;
    }

    // usage 在最后一个事件里单独给（choices 为空），所以先取用量再看 choices。
    _usage = _mergeUsage(_usage, event['usage']);

    final Object? choices = event['choices'];
    if (choices is! List || choices.isEmpty) return;

    final Object? first = choices.first;
    if (first is! Map<String, Object?>) return;

    // finish_reason 可能和最后一批 delta 同一个事件到达，所以两个都要处理，
    // 不能 else if。
    final String? finish = first['finish_reason'] as String?;
    if (finish != null) {
      _stopReason = _mapStopReason(finish);
    }

    final Object? delta = first['delta'];
    if (delta is! Map<String, Object?>) return;

    yield* _consumeDelta(delta);
  }

  Stream<StreamEvent> _consumeDelta(Map<String, Object?> delta) async* {
    // 思考内容：字段名按标记选。两个字段名都查是因为同一家的不同部署
    // 会用不同的名字（DeepSeek 官方是 reasoning_content，部分中转站转成
    // reasoning），而这两个键在正文里都不会出现，多查一个没有代价。
    if (compat.thinking != ThinkingFormat.none) {
      final String chunk =
          _stringOf(delta['reasoning_content']) ??
          _stringOf(delta['reasoning']) ??
          '';
      if (chunk.isNotEmpty) {
        _thinking.write(chunk);
        yield StreamThinkingDelta(message: snapshot(), delta: chunk);
      }
    }

    final String? content = _stringOf(delta['content']);
    if (content != null && content.isNotEmpty) {
      _text.write(content);
      yield StreamTextDelta(message: snapshot(), delta: content);
    }

    final Object? toolCalls = delta['tool_calls'];
    if (toolCalls is List) {
      yield* _consumeToolCalls(toolCalls);
    }
  }

  Stream<StreamEvent> _consumeToolCalls(List<Object?> raw) async* {
    for (final Object? item in raw) {
      if (item is! Map<String, Object?>) continue;

      // index 缺失时按已有数量兜底：少数端点在只有一个 tool call 时不发
      // index。用 length 而不是 0，否则第二个调用会覆盖第一个。
      final int index = (item['index'] as num?)?.toInt() ?? _calls.length;
      final _ToolCallState state = _calls.putIfAbsent(
        index,
        () => _ToolCallState(),
      );

      // id 只在第一个 delta 出现，后续 delta 里是 null——不能覆盖。
      final String? id = item['id'] as String?;
      if (id != null && id.isNotEmpty) state.id = id;

      final Object? function = item['function'];
      if (function is! Map<String, Object?>) continue;

      final String? name = function['name'] as String?;
      if (name != null && name.isNotEmpty) state.name = name;

      final String? args = _stringOf(function['arguments']);
      if (args == null || args.isEmpty) continue;

      state.arguments.write(args);
      yield StreamToolCallDelta(
        message: snapshot(),
        callId: state.id ?? '',
        toolName: state.name ?? '',
        argumentsDelta: args,
      );
    }
  }

  /// 当前的完整消息。
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

  /// 收尾。[forced] 非空时覆盖服务端给的停止原因（取消的情况）。
  ChatMessageModel finish(StopReason? forced) {
    if (forced != null) _stopReason = forced;
    // 服务端没给 finish_reason 又没出错：按有没有工具调用推断。
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

    // thinking 在前：模型先想后说，顺序反了界面上思考块会跑到正文下面。
    final String thinking = _thinking.toString();
    if (thinking.isNotEmpty) {
      // signature 留 null：openai 系没有签名机制。回传时由
      // _buildAssistantMessage 一律丢弃（那边有说明）。
      parts.add(ThinkingPart(thinking, modelId: modelId));
    }

    final String text = _text.toString();
    if (text.isNotEmpty) parts.add(TextPart(text));

    final List<int> indices = _calls.keys.toList()..sort();
    for (final int i in indices) {
      final _ToolCallState state = _calls[i]!;
      parts.add(
        ToolCallPart(
          id: state.id ?? '',
          name: state.name ?? '',
          // 流还没结束时是半个 JSON，parse 失败就先给空参数——收全了
          // 下一次 snapshot 自然就对了（§4-7）。
          arguments: _tryParseArgs(state.arguments.toString()),
        ),
      );
    }

    return parts;
  }

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

  /// 只接受字符串。
  ///
  /// 不用 `as String?`：兼容端点偶尔在 `content` 里塞 part 数组或 null，
  /// 硬转会抛类型错误把整条流打断。返回 null 表示"这个字段这次没有内容"。
  static String? _stringOf(Object? value) => value is String ? value : null;

  static String _errorTextOf(Object? error) {
    if (error is Map<String, Object?>) {
      final Object? message = error['message'];
      if (message is String && message.isNotEmpty) return message;
    }
    if (error is String && error.isNotEmpty) return error;
    return '未知的 API 错误';
  }

  static StopReason? _mapStopReason(String? raw) {
    return switch (raw) {
      'stop' => StopReason.stop,
      'tool_calls' => StopReason.toolUse,
      // 少数端点用旧的 function_call 名字。
      'function_call' => StopReason.toolUse,
      // length 必须单独一档：整批工具都不能执行（§5-9）。
      'length' => StopReason.length,
      'content_filter' => StopReason.error,
      _ => null,
    };
  }

  static TokenUsage _mergeUsage(TokenUsage current, Object? raw) {
    if (raw is! Map<String, Object?>) return current;

    int pick(String key, int fallback) =>
        (raw[key] as num?)?.toInt() ?? fallback;

    // 缓存命中数在嵌套的 prompt_tokens_details 里，不在顶层。
    int cacheRead = current.cacheReadTokens;
    final Object? details = raw['prompt_tokens_details'];
    if (details is Map<String, Object?>) {
      cacheRead = (details['cached_tokens'] as num?)?.toInt() ?? cacheRead;
    }

    int reasoning = current.reasoningTokens;
    final Object? outDetails = raw['completion_tokens_details'];
    if (outDetails is Map<String, Object?>) {
      reasoning =
          (outDetails['reasoning_tokens'] as num?)?.toInt() ?? reasoning;
    }

    return TokenUsage(
      inputTokens: pick('prompt_tokens', current.inputTokens),
      outputTokens: pick('completion_tokens', current.outputTokens),
      cacheReadTokens: cacheRead,
      // openai 系没有"写缓存"这个计费项（自动缓存，不单独收费），
      // 所以这一项永远是 0。anthropic 才有。
      cacheWriteTokens: current.cacheWriteTokens,
      reasoningTokens: reasoning,
    );
  }
}

class _ToolCallState {
  String? id;
  String? name;
  final StringBuffer arguments = StringBuffer();
}
