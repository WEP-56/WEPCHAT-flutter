import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_auth_storage.dart';
import 'package:wepchat/mcp/mcp_config.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/mcp/mcp_oauth.dart';
import 'package:wepchat/mcp/mcp_oauth_login.dart';

/// 完整授权码流程的本机集成测试：受保护资源、授权服务器元数据、动态客户端
/// 注册、令牌端点全部由临时回环服务扮演，不访问任何外部服务或凭据。
void main() {
  test('回环回调完成授权码交换，令牌连同绑定信息落盘', () async {
    final _OAuthFixture fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);

    final McpServerConfig config = fixture.serverConfig();
    final McpAuthStorage store = McpAuthStorage();
    Uri? authorizeUri;

    await runMcpOAuthLogin(
      server: config,
      endpoint: config.endpoint as McpRemoteEndpoint,
      store: store,
      token: CancellationToken.none,
      confirm: (McpAuthorizationRequest request) async {
        authorizeUri = request.authorizationUri;
        expect(request.host, fixture.originUri.host);
        expect(request.scope, 'tools');
        // 扮演浏览器：带着 state 回到回环回调地址。
        final Uri callback = Uri.parse(
          request.authorizationUri.queryParameters['redirect_uri']!,
        );
        final http.Response response = await http.get(
          callback.replace(
            queryParameters: <String, String>{
              'code': _OAuthFixture.authorizationCode,
              'state': request.authorizationUri.queryParameters['state']!,
            },
          ),
        );
        expect(response.statusCode, 200);
        expect(response.body, contains('授权成功'));
        return true;
      },
      openBrowser: (Uri uri) async {
        expect(uri.host, fixture.originUri.host);
        expect(uri.path, '/authorize');
      },
    );

    final Uri? issued = authorizeUri;
    expect(issued, isNotNull);
    expect(issued!.queryParameters['response_type'], 'code');
    expect(issued.queryParameters['code_challenge_method'], 'S256');
    expect(issued.queryParameters['resource'], '${fixture.origin}/mcp');
    expect(issued.queryParameters['scope'], 'tools');
    // 动态注册拿到的 client_id 只出现在授权地址里，必须被记下来。
    expect(
      issued.queryParameters['client_id'],
      _OAuthFixture.registeredClientId,
    );

    final McpOAuthTokenSet? token = store.tokenSet(config.id);
    expect(token, isNotNull);
    expect(token!.accessToken, 'access-token');
    expect(token.refreshToken, 'refresh-token');
    expect(token.issuer, fixture.origin);
    expect(token.resource.toString(), '${fixture.origin}/mcp');
    expect(token.clientId, _OAuthFixture.registeredClientId);
    expect(token.scope, 'tools');
    expect(token.expiresAt!.isAfter(DateTime.now()), isTrue);

    expect(fixture.unauthorizedRequests, 1);
    expect(fixture.registrations, 1);
    expect(fixture.tokenRequests, 1);
    expect(fixture.lastTokenForm['resource'], '${fixture.origin}/mcp');
    expect(fixture.lastTokenForm['code'], _OAuthFixture.authorizationCode);
    expect(fixture.lastTokenForm['code_verifier'], isNotEmpty);
  });

  test('无状态服务器先用协议错误拒绝 initialize，探测会退到 server/discover', () async {
    // 复现 GitHub / Figma / Google 那类 2026-07-28 服务器：协议校验在认证之前，
    // 缺 Mcp-Method 头的请求拿到的是协议错误而不是 401。
    final _OAuthFixture fixture = await _OAuthFixture.start(
      statelessOnly: true,
    );
    addTearDown(fixture.close);

    final McpServerConfig config = fixture.serverConfig();
    final McpAuthStorage store = McpAuthStorage();
    Uri? authorizeUri;

    await runMcpOAuthLogin(
      server: config,
      endpoint: config.endpoint as McpRemoteEndpoint,
      store: store,
      token: CancellationToken.none,
      confirm: (McpAuthorizationRequest request) async {
        authorizeUri = request.authorizationUri;
        await _completeInBrowser(request.authorizationUri);
        return true;
      },
      openBrowser: (_) async {},
    );

    expect(authorizeUri, isNotNull);
    expect(fixture.methodRejectedRequests, 1);
    expect(fixture.discoverRequests, 1);
    expect(store.tokenSet(config.id), isNotNull);
  });

  test('用户取消授权时不打开浏览器，也不保存令牌', () async {
    final _OAuthFixture fixture = await _OAuthFixture.start();
    addTearDown(fixture.close);
    final McpServerConfig config = fixture.serverConfig();
    final McpAuthStorage store = McpAuthStorage();

    await expectLater(
      runMcpOAuthLogin(
        server: config,
        endpoint: config.endpoint as McpRemoteEndpoint,
        store: store,
        token: CancellationToken.none,
        confirm: (_) async => false,
        openBrowser: (_) async => fail('取消后不该打开浏览器'),
      ),
      throwsA(isA<McpFailure>()),
    );
    expect(store.tokenSet(config.id), isNull);
    expect(fixture.tokenRequests, 0);
  });

  test('服务器确实要认证但没发布受保护资源元数据时，如实报告发现阶段失败', () async {
    final _OAuthFixture fixture = await _OAuthFixture.start(
      publishMetadata: false,
    );
    addTearDown(fixture.close);
    final McpServerConfig config = fixture.serverConfig();

    await expectLater(
      runMcpOAuthLogin(
        server: config,
        endpoint: config.endpoint as McpRemoteEndpoint,
        store: McpAuthStorage(),
        token: CancellationToken.none,
        confirm: (_) async => fail('发现失败时不该询问用户'),
        openBrowser: (_) async => fail('发现失败时不该打开浏览器'),
      ),
      throwsA(
        isA<McpFailure>().having(
          (McpFailure error) => error.message,
          'message',
          contains('发现阶段中断'),
        ),
      ),
    );
  });

  test('服务器完全不要求授权时给出明确错误而不是挂住', () async {
    final _OAuthFixture fixture = await _OAuthFixture.start(requireAuth: false);
    addTearDown(fixture.close);
    final McpServerConfig config = fixture.serverConfig();

    await expectLater(
      runMcpOAuthLogin(
        server: config,
        endpoint: config.endpoint as McpRemoteEndpoint,
        store: McpAuthStorage(),
        token: CancellationToken.none,
        confirm: (_) async => fail('不需要授权时不该询问用户'),
        openBrowser: (_) async => fail('不需要授权时不该打开浏览器'),
      ),
      throwsA(
        isA<McpFailure>().having(
          (McpFailure error) => error.message,
          'message',
          contains('没有要求 OAuth 授权'),
        ),
      ),
    );
  });
}

Future<void> _completeInBrowser(Uri authorizationUri) async {
  final Uri callback = Uri.parse(
    authorizationUri.queryParameters['redirect_uri']!,
  );
  final http.Response response = await http.get(
    callback.replace(
      queryParameters: <String, String>{
        'code': _OAuthFixture.authorizationCode,
        'state': authorizationUri.queryParameters['state']!,
      },
    ),
  );
  expect(response.statusCode, 200);
}

class _OAuthFixture {
  _OAuthFixture._(
    this._server, {
    required bool requireAuth,
    required bool statelessOnly,
    required bool publishMetadata,
  }) : _requireAuth = requireAuth,
       _statelessOnly = statelessOnly,
       _publishMetadata = publishMetadata;

  static const String authorizationCode = 'fixture-code';
  static const String registeredClientId = 'fixture-client';

  final HttpServer _server;
  final bool _requireAuth;
  final bool _statelessOnly;
  final bool _publishMetadata;

  int unauthorizedRequests = 0;
  int methodRejectedRequests = 0;
  int discoverRequests = 0;
  int registrations = 0;
  int tokenRequests = 0;
  Map<String, String> lastTokenForm = <String, String>{};

  String get origin => 'http://127.0.0.1:${_server.port}';
  Uri get originUri => Uri.parse(origin);

  static Future<_OAuthFixture> start({
    bool requireAuth = true,
    bool statelessOnly = false,
    bool publishMetadata = true,
  }) async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    final _OAuthFixture fixture = _OAuthFixture._(
      server,
      requireAuth: requireAuth,
      statelessOnly: statelessOnly,
      publishMetadata: publishMetadata,
    );
    server.listen(fixture._handle);
    return fixture;
  }

  McpServerConfig serverConfig() => McpServerConfig(
    id: 'oauth',
    name: '云端服务',
    endpoint: McpRemoteEndpoint(
      kind: McpTransportKind.streamableHttp,
      url: Uri.parse('$origin/mcp'),
      auth: McpRemoteAuth.oauth,
      oauth: McpOAuthClient(scopes: const <String>['tools']),
    ),
    timeout: const Duration(seconds: 10),
  );

  Future<void> close() => _server.close(force: true);

  Future<void> _handle(HttpRequest request) async {
    switch (request.uri.path) {
      case '/.well-known/oauth-protected-resource':
      case '/.well-known/oauth-protected-resource/mcp':
        if (!_publishMetadata) {
          await _notFound(request);
          return;
        }
        await _json(request, <String, Object?>{
          'resource': '$origin/mcp',
          'authorization_servers': <String>[origin],
          'scopes_supported': <String>['tools'],
        });
      case '/.well-known/oauth-authorization-server':
        if (!_publishMetadata) {
          await _notFound(request);
          return;
        }
        await _json(request, <String, Object?>{
          'issuer': origin,
          'authorization_endpoint': '$origin/authorize',
          'token_endpoint': '$origin/token',
          'registration_endpoint': '$origin/register',
          'code_challenge_methods_supported': <String>['S256'],
          'token_endpoint_auth_methods_supported': <String>['none'],
        });
      case '/register':
        registrations++;
        await _json(request, <String, Object?>{
          'client_id': registeredClientId,
          'token_endpoint_auth_method': 'none',
        });
      case '/token':
        tokenRequests++;
        lastTokenForm = Uri.splitQueryString(
          await utf8.decoder.bind(request).join(),
        );
        await _json(request, <String, Object?>{
          'access_token': 'access-token',
          'refresh_token': 'refresh-token',
          'token_type': 'Bearer',
          'expires_in': 3600,
          'scope': 'tools',
        });
      default:
        await _mcp(request);
    }
  }

  Future<void> _mcp(HttpRequest request) async {
    final String body = await utf8.decoder.bind(request).join();
    final String? method = request.headers.value('mcp-method');
    if (_statelessOnly && method == null) {
      // 2026-07-28 服务器先校验协议，认证层根本没被问到。
      methodRejectedRequests++;
      await _json(request, <String, Object?>{
        'jsonrpc': '2.0',
        'id': _requestId(body),
        'error': <String, Object?>{
          'code': -32601,
          'message': 'method not found',
        },
      }, status: HttpStatus.badRequest);
      return;
    }
    if (method == 'server/discover') discoverRequests++;
    if (_requireAuth && request.headers.value('authorization') == null) {
      unauthorizedRequests++;
      request.response.statusCode = HttpStatus.unauthorized;
      request.response.headers.set(
        'www-authenticate',
        _publishMetadata
            ? 'Bearer resource_metadata='
                  '"$origin/.well-known/oauth-protected-resource"'
            : 'Bearer',
      );
      await request.response.close();
      return;
    }
    await _json(request, <String, Object?>{
      'jsonrpc': '2.0',
      'id': _requestId(body),
      'result': <String, Object?>{
        'protocolVersion': '2025-11-25',
        'capabilities': <String, Object?>{},
        'serverInfo': <String, Object?>{'name': 'fixture', 'version': '1'},
      },
    });
  }

  static Object? _requestId(String body) {
    final Object? decoded = _tryDecode(body);
    return decoded is Map<String, Object?> ? decoded['id'] : 1;
  }

  static Object? _tryDecode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  Future<void> _notFound(HttpRequest request) async {
    request.response.statusCode = HttpStatus.notFound;
    await request.response.close();
  }

  Future<void> _json(
    HttpRequest request,
    Object body, {
    int status = HttpStatus.ok,
  }) async {
    request.response.statusCode = status;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode(body));
    await request.response.close();
  }
}
