import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wepchat/mcp/mcp_oauth.dart';
import 'package:wepchat/mcp/mcp_oauth_refresh.dart';

void main() {
  final McpOAuthTokenSet expired = McpOAuthTokenSet(
    accessToken: 'old',
    refreshToken: 'refresh-1',
    issuer: 'https://auth.example',
    resource: Uri.parse('https://mcp.example/mcp'),
    clientId: 'client-1',
  );

  MockClient discoveryThen(
    Future<http.Response> Function(http.Request request) token,
  ) => MockClient((http.Request request) {
    if (request.url.path == '/.well-known/oauth-authorization-server') {
      return Future<http.Response>.value(
        http.Response(
          jsonEncode(<String, Object?>{
            'issuer': 'https://auth.example',
            'token_endpoint': 'https://auth.example/token',
          }),
          200,
        ),
      );
    }
    return token(request);
  });

  test('刷新请求带上 resource 与 client_id，并覆盖轮换后的刷新令牌', () async {
    final List<http.BaseRequest> requests = <http.BaseRequest>[];
    final MockClient client = discoveryThen((http.Request request) async {
      requests.add(request);
      expect(request.url.toString(), 'https://auth.example/token');
      expect(request.body, contains('grant_type=refresh_token'));
      expect(request.body, contains('refresh_token=refresh-1'));
      expect(request.body, contains('client_id=client-1'));
      expect(
        request.body,
        contains('resource=https%3A%2F%2Fmcp.example%2Fmcp'),
      );
      // 公开客户端不加客户端认证头。
      expect(request.headers.containsKey('Authorization'), isFalse);
      return http.Response(
        jsonEncode(<String, Object?>{
          'access_token': 'new',
          'refresh_token': 'refresh-2',
          'expires_in': 3600,
          'scope': 'tools',
        }),
        200,
      );
    });

    final McpOAuthTokenSet refreshed = await McpOAuthRefresher().refresh(
      expired,
      client: client,
    );
    expect(refreshed.accessToken, 'new');
    expect(refreshed.refreshToken, 'refresh-2');
    expect(refreshed.scope, 'tools');
    // 绑定信息必须原样保留，否则令牌会被自己拒绝。
    expect(refreshed.issuer, 'https://auth.example');
    expect(refreshed.resource.toString(), 'https://mcp.example/mcp');
    expect(refreshed.clientId, 'client-1');
    expect(refreshed.expiresAt!.isAfter(DateTime.now()), isTrue);
    expect(requests, hasLength(1));
  });

  test('服务器未轮换刷新令牌时沿用旧值', () async {
    final MockClient client = discoveryThen(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{'access_token': 'new'}),
        200,
      ),
    );
    final McpOAuthTokenSet refreshed = await McpOAuthRefresher().refresh(
      expired,
      client: client,
    );
    expect(refreshed.refreshToken, 'refresh-1');
    // 没有 expires_in 时不做过期推断。
    expect(refreshed.expiresAt, isNull);
  });

  test('机密客户端使用 client_secret_basic', () async {
    final MockClient client = discoveryThen((http.Request request) async {
      expect(request.headers['Authorization'], startsWith('Basic '));
      return http.Response(
        jsonEncode(<String, Object?>{'access_token': 'new'}),
        200,
      );
    });
    await McpOAuthRefresher().refresh(
      expired,
      clientSecret: 'secret-1',
      client: client,
    );
  });

  test('缺少刷新条件、令牌端点失败或响应无效都明确失败', () async {
    final MockClient forbidden = MockClient(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{'error': 'invalid_grant'}),
        400,
      ),
    );
    final McpOAuthRefresher refresher = McpOAuthRefresher();

    // 没有 refresh_token 或 client_id 时不发请求。
    await expectLater(
      refresher.refresh(
        McpOAuthTokenSet(
          accessToken: 'old',
          issuer: 'https://auth.example',
          resource: Uri.parse('https://mcp.example/mcp'),
        ),
        client: forbidden,
      ),
      throwsA(isA<McpOAuthRefreshFailure>()),
    );

    await expectLater(
      refresher.refresh(expired, client: forbidden),
      throwsA(isA<McpOAuthRefreshFailure>()),
    );

    final MockClient missingToken = discoveryThen(
      (_) async => http.Response(
        jsonEncode(<String, Object?>{'token_type': 'Bearer'}),
        200,
      ),
    );
    await expectLater(
      refresher.refresh(expired, client: missingToken),
      throwsA(isA<McpOAuthRefreshFailure>()),
    );

    // 发现失败同样明确失败，不退化成"继续用旧令牌"。
    final MockClient unreachable = MockClient(
      (http.Request request) async => http.Response('nope', 404),
    );
    await expectLater(
      refresher.refresh(expired, client: unreachable),
      throwsA(isA<McpOAuthRefreshFailure>()),
    );
  });

  test('带路径的 issuer 会按 OIDC 变体继续探测', () async {
    final List<String> paths = <String>[];
    final MockClient client = MockClient((http.Request request) async {
      paths.add(request.url.toString());
      // 只有「路径追加」形态的 OIDC 变体可用，前面的候选端点一律 404。
      if (request.url.path.endsWith('/.well-known/openid-configuration')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'issuer': 'https://auth.example/tenant1',
            'token_endpoint': 'https://auth.example/tenant1/token',
          }),
          200,
        );
      }
      if (request.url.path.endsWith('/.well-known/oauth-authorization-server')) {
        return http.Response('not found', 404);
      }
      return http.Response(
        jsonEncode(<String, Object?>{'access_token': 'new'}),
        200,
      );
    });
    final McpOAuthTokenSet refreshed = await McpOAuthRefresher().refresh(
      McpOAuthTokenSet(
        accessToken: 'old',
        refreshToken: 'refresh-1',
        issuer: 'https://auth.example/tenant1',
        resource: Uri.parse('https://mcp.example/mcp'),
        clientId: 'client-1',
      ),
      client: client,
    );
    expect(refreshed.accessToken, 'new');
    expect(
      paths,
      contains('https://auth.example/tenant1/.well-known/openid-configuration'),
    );
  });
}
