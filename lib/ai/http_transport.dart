/// 流式 POST 的共享传输层（实施 TODO §4-10、§4-11）。
///
/// 三个适配器共用：重试策略、取消接线、错误响应读取都只实现一次。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/cancellation_token.dart';
import '../core/errors.dart';
import '../core/redact.dart';

/// 一次流式响应。
class StreamedBody {
  const StreamedBody({required this.statusCode, required this.stream});

  final int statusCode;
  final Stream<List<int>> stream;
}

/// 发流式请求的函数形状。
///
/// 适配器接这个 typedef 而不是直接调 [postStreaming]，测试就能塞进一段
/// 录好的 SSE 响应，不必起 HTTP server、不必联网。生产代码用默认值。
typedef StreamPoster =
    Future<StreamedBody> Function({
      required Uri url,
      required Map<String, String> headers,
      required Map<String, Object?> body,
      required CancellationToken token,
    });

/// 重试上限。超过就把最后一次的错误交出去。
const int _kMaxAttempts = 3;

/// 发一个流式 POST，带重试。
///
/// 重试规则（§4-10）：
/// - 只对 429 / 5xx / 连接失败重试
/// - 指数退避，尊重 `Retry-After`
/// - **首字节到达后不再重试**。已经吐给界面的文本无法回收，重试会产生
///   重复内容。所以重试只发生在"拿到响应头之前"这个窗口里——一旦
///   [StreamedBody] 返回，调用方就自己负责了。
///
/// [token] 取消时调 `client.close()` 中断底层连接：这是 `http` 包唯一
/// 能真正掐断进行中请求的手段，`Future` 本身不可取消（§3-2）。
Future<StreamedBody> postStreaming({
  required Uri url,
  required Map<String, String> headers,
  required Map<String, Object?> body,
  required CancellationToken token,
}) async {
  Object? lastError;

  for (int attempt = 1; attempt <= _kMaxAttempts; attempt++) {
    token.throwIfCancelled();

    final http.Client client = http.Client();
    bool handedOff = false;

    // 取消时关掉 client。已经交给调用方的流也会因此断开——正是要的效果。
    token.onCancel(client.close);

    try {
      final http.Request request = http.Request('POST', url)
        ..headers.addAll(headers)
        // 显式 UTF-8：`http` 默认 latin-1，中文 prompt 会变成乱码，
        // 而且服务端不会报错，只是模型收到垃圾。
        ..bodyBytes = utf8.encode(jsonEncode(body));

      final Stopwatch sw = Stopwatch()..start();
      final http.StreamedResponse response = await client.send(request);
      sw.stop();

      // 只记 method / host / path / status / 耗时。
      // 不记 header、不记 body、不记 key（§4-11、AGENTS.md §2.4）。
      _log(
        'POST ${url.host}${url.path} → ${response.statusCode} '
        '(${sw.elapsedMilliseconds}ms)',
      );

      if (response.statusCode == 200) {
        handedOff = true;
        // client 不在这里 close：流还没读完。调用方读完流后连接自然关闭，
        // 取消时由上面注册的 onCancel 关掉。
        return StreamedBody(
          statusCode: response.statusCode,
          stream: response.stream,
        );
      }

      // 非 200：把 body 读出来当错误信息，然后决定重不重试。
      final String errorBody = await response.stream.bytesToString();
      final WepError error = _toError(response.statusCode, errorBody);

      if (!_isRetryable(response.statusCode) || attempt == _kMaxAttempts) {
        throw error;
      }

      lastError = error;
      await _backoff(attempt, response.headers['retry-after'], token);
    } on WepError {
      // 已经是领域错误（上面 throw 的，或 token 取消）：直接向上抛，
      // 不当成"连接失败"再重试一轮。
      rethrow;
    } on Object catch (e) {
      // 连接层失败（DNS、TCP、TLS、对端断开）。可重试。
      if (attempt == _kMaxAttempts) {
        throw NetworkError(
          '请求失败',
          context: <String, Object?>{
            'host': url.host,
            'attempts': attempt,
            'cause': redact(e.toString()),
          },
        );
      }
      lastError = e;
      await _backoff(attempt, null, token);
    } finally {
      if (!handedOff) client.close();
    }
  }

  // 循环必然从 return 或 throw 出去，走到这里说明上面的逻辑漏了分支。
  throw NetworkError(
    '请求重试用尽',
    context: <String, Object?>{'cause': redact(lastError.toString())},
  );
}

bool _isRetryable(int status) => status == 429 || status >= 500;

/// 指数退避：1s、2s、4s。有 `Retry-After` 就听服务端的。
Future<void> _backoff(
  int attempt,
  String? retryAfter,
  CancellationToken token,
) async {
  Duration delay = Duration(seconds: 1 << (attempt - 1));

  final int? seconds = retryAfter == null ? null : int.tryParse(retryAfter);
  if (seconds != null && seconds > 0) {
    // 服务端说的时长可能很长（限流恢复窗口），但也不能无限等。
    delay = Duration(seconds: seconds.clamp(1, 60));
  }

  // 等待期间可被取消：不然用户点了停止还要干等一分钟。
  await Future.any<void>(<Future<void>>[
    Future<void>.delayed(delay),
    token.whenCancelled,
  ]);
  token.throwIfCancelled();
}

/// 把 HTTP 错误响应转成领域错误。
///
/// 三家的错误体结构不同，但都把人类可读的说明放在 `error.message`
/// （anthropic / openai 一致）。取不到就用原始 body。
WepError _toError(int status, String rawBody) {
  String? providerMessage;
  try {
    final Object? decoded = jsonDecode(rawBody);
    if (decoded is Map<String, Object?>) {
      final Object? error = decoded['error'];
      if (error is Map<String, Object?>) {
        providerMessage = error['message'] as String?;
      } else if (error is String) {
        providerMessage = error;
      }
    }
  } on FormatException {
    // 不是 JSON（网关返回的 HTML 错误页之类）。用原始内容，截断。
  }
  providerMessage ??= rawBody.length > 500
      ? '${rawBody.substring(0, 500)}…'
      : rawBody;

  if (status == 401 || status == 403) {
    return AuthError(
      'API key 无效或无权访问',
      context: <String, Object?>{
        'status': status,
        'providerMessage': redact(providerMessage),
      },
    );
  }

  return ApiError(
    status == 429 ? '请求过于频繁' : 'API 返回错误',
    statusCode: status,
    providerMessage: redact(providerMessage),
  );
}

/// 日志出口。所有内容先过 [redact]（§3-4）。
///
/// M1 先打到 stdout。接了正式日志设施之后改这一个函数就行——
/// 调用点都在这个文件里。
void _log(String message) {
  // ignore: avoid_print
  print('[ai] ${redact(message)}');
}
