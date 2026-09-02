import 'dart:async';
import 'dart:convert';

import '../../core/cancellation_token.dart';
import '../../core/errors.dart';
import '../http_transport.dart';
import '../messages.dart';
import '../provider_api.dart';
import '../sse.dart';
import '../stream_event.dart';
import 'completions_accumulator.dart';
import 'openai_request.dart';

/// openai-completions 适配器（实施 TODO §4-7）。
///
/// 这一个类同时服务 OpenAI、DeepSeek、Kimi、GLM、Qwen、本地 vLLM——差异全
/// 在 `ModelSpec.compat` 里，这里没有一处按厂商分支（§4 开头的决定）。
/// [baseUrl] 由 provider 配置给，所以换端点不需要改代码。
class OpenAiCompletionsApi extends ProviderApi {
  OpenAiCompletionsApi({
    required String apiKey,
    String baseUrl = 'https://api.openai.com/v1',
    StreamPoster? poster,
  }) : _apiKey = apiKey,
       _baseUrl = _trimTrailingSlash(baseUrl),
       _post = poster ?? postStreaming;

  final String _apiKey;
  final String _baseUrl;

  /// 注入点：测试塞录好的 SSE，生产用 [postStreaming]。
  final StreamPoster _post;

  @override
  Stream<StreamEvent> stream(ProviderRequest request, CancellationToken token) {
    return _stream(request, token);
  }

  Stream<StreamEvent> _stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    final CompletionsAccumulator acc = CompletionsAccumulator(
      modelId: request.model.id,
      compat: request.model.compat,
    );

    // 整个方法体包在 try 里：契约要求永不抛、永不 addError（§4-2）。
    try {
      final StreamedBody body = await _post(
        url: Uri.parse('$_baseUrl/chat/completions'),
        headers: <String, String>{
          'content-type': 'application/json',
          'authorization': 'Bearer $_apiKey',
        },
        body: buildCompletionsRequest(request),
        token: token,
      );

      yield StreamStart(message: acc.snapshot());

      await for (final SseEvent event in parseSse(body.stream)) {
        if (token.isCancelled) {
          yield StreamDone(message: acc.finish(StopReason.aborted));
          return;
        }
        // openai 用 `data: [DONE]` 收尾，不像 anthropic 有具名事件。
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
      // 丢一个 delta 比丢整轮回复好（同 anthropic 适配器的处理）。
      return null;
    }
  }

  /// 用户配 base url 时很容易多写一个斜杠，拼出 `//chat/completions`。
  /// 有的网关会 404，有的会重定向丢掉 POST body——都不好查，所以在入口修掉。
  static String _trimTrailingSlash(String url) {
    String out = url;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
