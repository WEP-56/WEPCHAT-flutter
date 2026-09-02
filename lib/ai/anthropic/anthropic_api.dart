import 'dart:async';
import 'dart:convert';

import '../../core/cancellation_token.dart';
import '../../core/errors.dart';
import '../http_transport.dart';
import '../messages.dart';
import '../provider_api.dart';
import '../sse.dart';
import '../stream_event.dart';
import 'anthropic_request.dart';

/// anthropic-messages 适配器（实施 TODO §4-9）。
class AnthropicApi extends ProviderApi {
  AnthropicApi({
    required String apiKey,
    String baseUrl = 'https://api.anthropic.com',
    StreamPoster? poster,
  }) : _apiKey = apiKey,
       _baseUrl = baseUrl,
       _post = poster ?? postStreaming;

  final String _apiKey;
  final String _baseUrl;

  /// 注入点：测试塞录好的 SSE，生产用 [postStreaming]。
  final StreamPoster _post;

  /// 需要显式声明的 API 版本。不带这个头请求直接 400。
  static const String _apiVersion = '2023-06-01';

  @override
  Stream<StreamEvent> stream(ProviderRequest request, CancellationToken token) {
    // async* 而不是 async：事件要边收边吐，攒完再返回就没有流式效果了。
    return _stream(request, token);
  }

  Stream<StreamEvent> _stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    final _AnthropicAccumulator acc = _AnthropicAccumulator(
      modelId: request.model.id,
    );

    // 整个方法体包在 try 里：契约要求永不抛、永不 addError（§4-2）。
    // 任何失败都变成一个带 stopReason 的 StreamDone。
    try {
      final StreamedBody body = await _post(
        url: Uri.parse('$_baseUrl/v1/messages'),
        headers: <String, String>{
          'content-type': 'application/json',
          'x-api-key': _apiKey,
          'anthropic-version': _apiVersion,
        },
        body: buildAnthropicRequest(request),
        token: token,
      );

      yield StreamStart(message: acc.snapshot());

      await for (final SseEvent event in parseSse(body.stream)) {
        if (token.isCancelled) {
          yield StreamDone(message: acc.finish(StopReason.aborted));
          return;
        }
        if (event.isDone) break;

        final Object? decoded = _tryDecode(event.data);
        if (decoded is! Map<String, Object?>) continue;

        yield* acc.consume(decoded);
      }

      yield StreamDone(message: acc.finish(null));
    } on CancelledException {
      yield StreamDone(message: acc.finish(StopReason.aborted));
    } on WepError catch (e) {
      yield StreamDone(message: acc.fail(e.message));
    } on Object catch (e) {
      yield StreamDone(message: acc.fail(e.toString()));
    }
  }

  Object? _tryDecode(String data) {
    try {
      return jsonDecode(data);
    } on FormatException {
      // 半个 JSON 不该出现（SSE 解析器保证事件完整），出现了就跳过这个事件
      // 而不是让整条流失败——丢一个 delta 比丢整轮回复好。
      return null;
    }
  }
}

/// 流式响应的累积器。
///
/// anthropic 的结构是 `content_block_start` → 若干 `content_block_delta`
/// → `content_block_stop`，块之间用 index 区分。tool_use 的参数是
/// `input_json_delta` 的字符串增量，收全了才是合法 JSON（§4-9）。
class _AnthropicAccumulator {
  _AnthropicAccumulator({required this.modelId});

  final String modelId;

  /// index → 该块的累积状态。用 Map 而不是 List：服务端不保证 index 连续。
  final Map<int, _BlockState> _blocks = <int, _BlockState>{};

  TokenUsage _usage = const TokenUsage();
  StopReason? _stopReason;
  String? _errorMessage;

  Stream<StreamEvent> consume(Map<String, Object?> event) async* {
    final String? type = event['type'] as String?;

    switch (type) {
      case 'message_start':
        // 首个 usage 在这里给：input / cache 相关的数字只出现一次。
        final Object? message = event['message'];
        if (message is Map<String, Object?>) {
          _usage = _mergeUsage(_usage, message['usage']);
        }

      case 'content_block_start':
        final int index = (event['index'] as num?)?.toInt() ?? 0;
        final Object? block = event['content_block'];
        if (block is Map<String, Object?>) {
          _blocks[index] = _BlockState.fromStart(block);
        }

      case 'content_block_delta':
        final int index = (event['index'] as num?)?.toInt() ?? 0;
        final Object? delta = event['delta'];
        if (delta is! Map<String, Object?>) return;

        final _BlockState? state = _blocks[index];
        if (state == null) return; // 没见过 start 的 delta，跳过

        final String deltaType = delta['type'] as String? ?? '';
        switch (deltaType) {
          case 'text_delta':
            final String chunk = delta['text'] as String? ?? '';
            state.text.write(chunk);
            yield StreamTextDelta(message: snapshot(), delta: chunk);

          case 'thinking_delta':
            final String chunk = delta['thinking'] as String? ?? '';
            state.text.write(chunk);
            yield StreamThinkingDelta(message: snapshot(), delta: chunk);

          case 'signature_delta':
            // 签名分片到达。必须原样保留（§4-9）。
            state.signature.write(delta['signature'] as String? ?? '');

          case 'input_json_delta':
            final String chunk = delta['partial_json'] as String? ?? '';
            state.text.write(chunk);
            yield StreamToolCallDelta(
              message: snapshot(),
              callId: state.id ?? '',
              toolName: state.name ?? '',
              argumentsDelta: chunk,
            );
        }

      case 'message_delta':
        final Object? delta = event['delta'];
        if (delta is Map<String, Object?>) {
          _stopReason = _mapStopReason(delta['stop_reason'] as String?);
        }
        // output_tokens 的最终值在这里。
        _usage = _mergeUsage(_usage, event['usage']);

      case 'error':
        final Object? error = event['error'];
        if (error is Map<String, Object?>) {
          _errorMessage = error['message'] as String? ?? '未知的 API 错误';
        } else {
          _errorMessage = '未知的 API 错误';
        }
        _stopReason = StopReason.error;

      // content_block_stop / message_stop / ping：没有需要累积的内容。
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
    // 服务端没给 stop_reason 又没出错：按有没有工具调用推断。
    _stopReason ??= _buildParts().any((ContentPart p) => p is ToolCallPart)
        ? StopReason.toolUse
        : StopReason.stop;
    return snapshot();
  }

  ChatMessageModel fail(String message) {
    _stopReason = StopReason.error;
    _errorMessage = message;
    return snapshot();
  }

  /// 按 index 升序把块拼成 parts。
  List<ContentPart> _buildParts() {
    final List<int> indices = _blocks.keys.toList()..sort();
    final List<ContentPart> parts = <ContentPart>[];

    for (final int i in indices) {
      final _BlockState state = _blocks[i]!;
      final String text = state.text.toString();

      switch (state.kind) {
        case _BlockKind.text:
          if (text.isNotEmpty) parts.add(TextPart(text));

        case _BlockKind.thinking:
          if (text.isNotEmpty) {
            final String sig = state.signature.toString();
            parts.add(
              ThinkingPart(
                text,
                signature: sig.isEmpty ? null : sig,
                modelId: modelId,
              ),
            );
          }

        case _BlockKind.toolUse:
          // 流还没结束时 text 是半个 JSON，parse 一定失败——
          // 失败就先给空参数，等收全了下一次 snapshot 自然就对了（§4-7）。
          final Map<String, Object?> args = _tryParseArgs(text);
          parts.add(
            ToolCallPart(
              id: state.id ?? '',
              name: state.name ?? '',
              arguments: args,
            ),
          );
      }
    }
    return parts;
  }

  Map<String, Object?> _tryParseArgs(String raw) {
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

  static StopReason? _mapStopReason(String? raw) {
    return switch (raw) {
      'end_turn' => StopReason.stop,
      'stop_sequence' => StopReason.stop,
      'tool_use' => StopReason.toolUse,
      // max_tokens 必须映射成 length：整批工具都不能执行（§5-9）。
      'max_tokens' => StopReason.length,
      _ => null,
    };
  }

  static TokenUsage _mergeUsage(TokenUsage current, Object? raw) {
    if (raw is! Map<String, Object?>) return current;
    int pick(String key, int fallback) =>
        (raw[key] as num?)?.toInt() ?? fallback;

    return TokenUsage(
      inputTokens: pick('input_tokens', current.inputTokens),
      outputTokens: pick('output_tokens', current.outputTokens),
      cacheReadTokens: pick('cache_read_input_tokens', current.cacheReadTokens),
      cacheWriteTokens: pick(
        'cache_creation_input_tokens',
        current.cacheWriteTokens,
      ),
      reasoningTokens: current.reasoningTokens,
    );
  }
}

enum _BlockKind { text, thinking, toolUse }

/// 一个 content block 的累积状态。
class _BlockState {
  _BlockState({required this.kind, this.id, this.name});

  factory _BlockState.fromStart(Map<String, Object?> block) {
    final String type = block['type'] as String? ?? 'text';
    return switch (type) {
      'thinking' => _BlockState(kind: _BlockKind.thinking),
      'tool_use' => _BlockState(
        kind: _BlockKind.toolUse,
        id: block['id'] as String?,
        name: block['name'] as String?,
      ),
      _ => _BlockState(kind: _BlockKind.text),
    };
  }

  final _BlockKind kind;
  final String? id;
  final String? name;

  /// 正文 / 思考内容 / tool 参数的 JSON 增量，三者复用这一个 buffer。
  final StringBuffer text = StringBuffer();
  final StringBuffer signature = StringBuffer();
}
