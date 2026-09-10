import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/mcp/mcp_oauth_redirect.dart';

/// 只使用本机回环，不访问外部服务。
void main() {
  test('只接受 state 匹配的回调，并交回授权码与 issuer', () async {
    final McpOAuthRedirect redirect = await McpOAuthRedirect.start();
    addTearDown(redirect.close);
    expect(redirect.redirectUri.host, '127.0.0.1');
    expect(redirect.redirectUri.path, '/callback');

    final Future<Map<String, String>> waiting = redirect.wait(
      CancellationToken.none,
      state: 'expected',
      timeout: const Duration(seconds: 10),
    );

    // state 不匹配的回调按规范丢弃，不结束等待。
    final http.Response stale = await http.get(
      redirect.redirectUri.replace(
        queryParameters: <String, String>{'code': 'x', 'state': 'other'},
      ),
    );
    expect(stale.statusCode, 200);

    final http.Response fresh = await http.get(
      redirect.redirectUri.replace(
        queryParameters: <String, String>{
          'code': 'good',
          'state': 'expected',
          'iss': 'https://auth.example',
        },
      ),
    );
    expect(fresh.statusCode, 200);

    final Map<String, String> params = await waiting;
    expect(params['code'], 'good');
    expect(params['iss'], 'https://auth.example');
  });

  test('授权服务器返回 error 时立即失败', () async {
    final McpOAuthRedirect redirect = await McpOAuthRedirect.start();
    addTearDown(redirect.close);
    // 先挂上断言再触发回调，否则失败会在没人接收的窗口里变成未处理异常。
    final Future<void> expectation = expectLater(
      redirect.wait(
        CancellationToken.none,
        state: 'expected',
        timeout: const Duration(seconds: 10),
      ),
      throwsA(isA<McpFailure>()),
    );
    await http.get(
      redirect.redirectUri.replace(
        queryParameters: <String, String>{'error': 'access_denied'},
      ),
    );
    await expectation;
  });

  test('没人回调时按超时结束，非回调路径返回 404', () async {
    final McpOAuthRedirect redirect = await McpOAuthRedirect.start();
    addTearDown(redirect.close);
    await expectLater(
      redirect.wait(
        CancellationToken.none,
        state: 's',
        timeout: const Duration(milliseconds: 50),
      ),
      throwsA(isA<McpFailure>()),
    );
    final http.Response other = await http.get(
      redirect.redirectUri.replace(path: '/elsewhere'),
    );
    expect(other.statusCode, HttpStatus.notFound);
  });

  test('指定端口被占用时给出可诊断的错误', () async {
    final HttpServer taken = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    addTearDown(() => taken.close(force: true));
    await expectLater(
      McpOAuthRedirect.start(port: taken.port),
      throwsA(
        isA<McpFailure>().having(
          (McpFailure error) => error.message,
          'message',
          contains('${taken.port}'),
        ),
      ),
    );
  });
}
