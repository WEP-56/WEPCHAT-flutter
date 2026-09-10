import 'dart:async';
import 'dart:io';

import '../core/cancellation_token.dart';
import 'mcp_connection.dart';

/// 回环重定向接收器（RFC 8252 §7.3 + MCP 授权章节）。
///
/// 只绑定 `127.0.0.1`，只处理一个 `GET /callback`，收到的授权码立刻交给上层
/// 换取令牌。端口留空时由系统分配：规范明确允许本机回环使用任意端口，这也是
/// 应用无需注册自定义 URL scheme 的原因。
final class McpOAuthRedirect {
  McpOAuthRedirect._(this._server)
    : redirectUri = Uri(
        scheme: 'http',
        host: '127.0.0.1',
        port: _server.port,
        path: '/callback',
      ) {
    _server.listen(_handle);
  }

  /// 最多容忍几个 state 不匹配的回调，防止被无关请求拖住。
  static const int _maxMismatchedCallbacks = 4;

  static Future<McpOAuthRedirect> start({int? port}) async {
    try {
      return McpOAuthRedirect._(
        await HttpServer.bind(InternetAddress.loopbackIPv4, port ?? 0),
      );
    } on SocketException catch (error) {
      throw McpFailure(
        port == null
            ? '无法启动本机回环回调端口：${error.osError?.message ?? '端口不可用'}'
            : '无法在端口 $port 启动回环回调：${error.osError?.message ?? '端口被占用'}。'
                  '请改用自动端口或换一个端口。',
      );
    }
  }

  final HttpServer _server;
  final Uri redirectUri;
  final StreamController<Map<String, String>> _callbacks =
      StreamController<Map<String, String>>();
  bool _closed = false;

  /// 等一个 `state` 匹配的回调，返回它的查询参数（含 `code`，可能含 `iss`）。
  ///
  /// state 不匹配或缺少授权码的回调按规范丢弃并继续等待；授权服务器显式返回
  /// `error` 则立即失败。
  Future<Map<String, String>> wait(
    CancellationToken token, {
    required String state,
    required Duration timeout,
  }) async {
    token.throwIfCancelled();
    final StreamIterator<Map<String, String>> callbacks =
        StreamIterator<Map<String, String>>(_callbacks.stream);
    final void Function() unregister = token.onCancel(() {
      unawaited(callbacks.cancel());
    });
    final DateTime deadline = DateTime.now().add(timeout);
    try {
      int mismatches = 0;
      while (await _next(callbacks, deadline)) {
        final Map<String, String> params = callbacks.current;
        final String? error = params['error'];
        if (error != null) {
          throw McpFailure('授权服务器拒绝了本次授权：$error');
        }
        if (!params.containsKey('code')) continue;
        if (params['state'] != state) {
          if (++mismatches > _maxMismatchedCallbacks) {
            throw const McpFailure('多次收到 state 不匹配的回调，已停止等待授权');
          }
          continue;
        }
        return params;
      }
      if (token.isCancelled) throw const CancelledException();
      if (_closed) throw const McpFailure('授权等待已取消');
      throw const McpFailure('等待授权回调超时，请重新点击「登录授权」');
    } finally {
      unregister();
      unawaited(callbacks.cancel());
    }
  }

  Future<bool> _next(
    StreamIterator<Map<String, String>> callbacks,
    DateTime deadline,
  ) {
    final Duration remaining = deadline.difference(DateTime.now());
    if (remaining <= Duration.zero) return Future<bool>.value(false);
    return callbacks.moveNext().timeout(
      remaining,
      onTimeout: () => false,
    );
  }

  Future<void> _handle(HttpRequest request) async {
    final Map<String, String> params = request.uri.queryParameters;
    if (request.method != 'GET' || request.uri.path != redirectUri.path) {
      await _reply(request, HttpStatus.notFound, '地址无效', '这个地址不是授权回调地址。');
      return;
    }
    if (params.containsKey('code') || params.containsKey('error')) {
      _callbacks.add(params);
      await _reply(
        request,
        HttpStatus.ok,
        params.containsKey('error') ? '授权未完成' : '授权成功',
        params.containsKey('error')
            ? '授权未完成，请回到 WePChat 查看提示后重试。'
            : '授权成功，请回到 WePChat。',
      );
      return;
    }
    await _reply(request, HttpStatus.badRequest, '请求无效', '回调和授权请求没有对应关系。');
  }

  Future<void> _reply(
    HttpRequest request,
    int status,
    String title,
    String message,
  ) async {
    request.response
      ..statusCode = status
      ..headers.contentType = ContentType.html
      ..write(
        '<!doctype html><html lang="zh"><head><meta charset="utf-8">'
        '<meta name="viewport" content="width=device-width,initial-scale=1">'
        '<title>$title</title></head>'
        '<body style="margin:0;display:flex;align-items:center;justify-content:center;'
        'min-height:100vh;background:#111214;color:#e8e8ea;'
        'font:15px/1.7 system-ui,-apple-system,\'Segoe UI\',sans-serif">'
        '<main style="max-width:22em;padding:2em;text-align:center">'
        '<h1 style="margin:0 0 .6em;font-size:17px;font-weight:500">$title</h1>'
        '<p style="margin:0;color:#9a9aa2">$message</p>'
        '</main></body></html>',
      );
    await request.response.close();
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _server.close(force: true);
    // 单订阅流的 close future 只在有人读到结束事件时才完成。没人等回调时
    // （用户取消、服务器不要求授权）它永远不会完成，所以不能 await。
    unawaited(_callbacks.close());
  }
}
