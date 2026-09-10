import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/mcp/mcp_auth_storage.dart';
import 'package:wepchat/mcp/mcp_oauth.dart';

void main() {
  McpOAuthTokenSet token({
    String access = 'access',
    String? refresh,
    String? clientId,
    DateTime? expiresAt,
  }) => McpOAuthTokenSet(
    accessToken: access,
    refreshToken: refresh,
    clientId: clientId,
    expiresAt: expiresAt,
    issuer: 'https://auth.example',
    resource: Uri.parse('https://mcp.example/mcp'),
  );

  test('令牌连同绑定信息一起往返，结构不完整的记录不当作有效授权', () {
    final McpOAuthTokenSet original = token(
      refresh: 'refresh',
      clientId: 'client',
      expiresAt: DateTime.utc(2026),
    );
    final McpOAuthTokenSet? parsed = McpOAuthTokenSet.fromJson(
      original.toJson(),
    );
    expect(parsed, isNotNull);
    expect(parsed!.accessToken, 'access');
    expect(parsed.refreshToken, 'refresh');
    expect(parsed.clientId, 'client');
    expect(parsed.expiresAt, DateTime.utc(2026));
    expect(parsed.issuer, 'https://auth.example');
    expect(parsed.resource.toString(), 'https://mcp.example/mcp');

    expect(McpOAuthTokenSet.fromJson(null), isNull);
    expect(
      McpOAuthTokenSet.fromJson(<String, Object?>{'accessToken': 'a'}),
      isNull,
    );
    expect(
      McpOAuthTokenSet.fromJson(<String, Object?>{
        'accessToken': 'a',
        'issuer': 'https://auth.example',
        'resource': 'not-an-absolute-uri',
      }),
      isNull,
    );
  });

  test('过期判定留出提前量，缺刷新条件时不尝试刷新', () {
    final DateTime now = DateTime.utc(2026, 1, 1, 12);
    expect(
      token(expiresAt: now.add(const Duration(minutes: 5))).isExpired(now),
      isFalse,
    );
    // 到期前 30 秒即视为过期，避免请求在途中失效。
    expect(
      token(expiresAt: now.add(const Duration(seconds: 10))).isExpired(now),
      isTrue,
    );
    // 服务器没给 expires_in 时交给服务器用 401 判定。
    expect(token().isExpired(now), isFalse);

    expect(token(refresh: 'r', clientId: 'c').canRefresh, isTrue);
    expect(token(refresh: 'r').canRefresh, isFalse);
    expect(token(clientId: 'c').canRefresh, isFalse);
  });

  test('存储同步读、写入通知宿主，重复清除不产生多余通知', () async {
    int changes = 0;
    final McpAuthStorage storage = McpAuthStorage(onChanged: () => changes++);
    expect(storage.tokenSet('a'), isNull);

    await storage.saveTokenSet('a', token());
    expect(storage.tokenSet('a'), isNotNull);
    expect(changes, 1);

    await storage.saveTokenSet('a', null);
    expect(storage.tokenSet('a'), isNull);
    expect(changes, 2);

    await storage.saveTokenSet('a', null);
    expect(changes, 2);
  });

  test('解码会跳过损坏的记录并保留其余记录', () {
    final Map<String, McpOAuthTokenSet> decoded = McpAuthStorage.decode(
      <String, Object?>{
        'good': token().toJson(),
        'bad': 'not-an-object',
        'empty': <String, Object?>{},
      },
    );
    expect(decoded.keys, <String>['good']);
    expect(McpAuthStorage.decode(null), isEmpty);
  });
}
