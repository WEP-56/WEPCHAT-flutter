import 'dart:async';
import 'dart:convert';

import '../../core/cancellation_token.dart';
import '../../core/errors.dart';
import '../http_transport.dart';
import '../messages.dart';
import '../provider_api.dart';
import '../sse.dart';
import '../stream_event.dart';
import 'responses_accumulator.dart';
import 'responses_request.dart';

/// openai-responses 适配器（实施 TODO §4-8）。
class OpenAiResponsesApi extends ProviderApi {
  OpenAiResponsesApi({
    required String apiKey,
    String baseUrl = 'https://api.openai.com/v1',
    StreamPoster? poster,
  })  : _apiKey = apiKey,
        _baseUrl = _trimTrailingSlash(baseUrl),
        _post = poster ?? postStreaming;

  final String _apiKey;
  final String _baseUrl;
  final StreamPoster _post;

  @override
  Stream<StreamEvent> stream(
    ProviderRequest request,
    CancellationToken token,
  ) {
    return _stream(request, token);
  }

  Stream<StreamEvent> _stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    final ResponsesAccumulator acc = ResponsesAccumulator(
      modelId: request.model.id,
    );

    try {
      final StreamedBody body = await _post(
        url: Uri.parse('$_baseUrl/responses'),
        headers: <String, String>{
          'content-type': 'application/json',
          'authorization': 'Bearer $_apiKey',
        },
        body: buildResponsesRequest(request),
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
      return null;
    }
  }

  static String _trimTrailingSlash(String url) {
    String out = url;
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }
}
