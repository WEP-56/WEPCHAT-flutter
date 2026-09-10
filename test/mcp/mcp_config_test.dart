import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/mcp/mcp_config.dart';
import 'package:wepchat/mcp/mcp_oauth.dart';
import 'package:wepchat/platform/settings_store.dart';
import 'package:wepchat/state/app_settings.dart';
import 'package:wepchat/tools/tool_permission.dart';

import 'mcp_test_support.dart';

void main() {
  test('旧设置默认关闭 MCP，新服务器默认询问', () {
    expect(McpSettings.fromJson(null).enabled, isFalse);
    final McpServerConfig server = McpServerConfig(
      id: 'local',
      name: 'Local',
      endpoint: McpStdioEndpoint(command: 'uvx'),
    );
    expect(server.permission, ToolPermission.ask);
  });

  test('网络和 stdio 配置按原语义持久化', () {
    final McpSettings config = McpSettings(
      enabled: true,
      servers: <McpServerConfig>[
        remoteServer(),
        McpServerConfig(
          id: 'local',
          name: '本地服务',
          endpoint: McpStdioEndpoint(
            command: 'npx',
            arguments: const <String>['-y', 'example-server', r'D:\资料'],
            environment: const <String, String>{'TOKEN': 'test-value'},
            workingDirectory: r'D:\work',
          ),
        ),
      ],
    );
    expect(McpSettings.fromJson(config.toJson()).toJson(), config.toJson());
  });

  test('MCP 权限持久化与总开关保持一致', () {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);
    final McpServerConfig server = remoteServer();
    settings.saveMcpServer(server);
    expect(
      settings.permissionOrAsk(server.permissionId),
      ToolPermission.denied,
    );
    settings.setMcpEnabled(true);
    expect(
      settings.permissionOrAsk(server.permissionId),
      ToolPermission.allowed,
    );
    expect(
      McpSettings.fromJson(
        settings.toJson()['mcp'],
      ).server(server.id)!.permission,
      ToolPermission.allowed,
    );
    settings.saveMcpServer(server.copyWith(enabled: false));
    expect(
      settings.permissionOrAsk(server.permissionId),
      ToolPermission.denied,
    );
    settings.removeMcpServer(server.id);
    expect(
      settings.permissionOrAsk(server.permissionId),
      ToolPermission.denied,
    );
  });

  test('重复服务器、未知传输和错误参数类型明确失败', () {
    expect(
      () => McpSettings(
        servers: <McpServerConfig>[remoteServer(), remoteServer()],
      ),
      throwsFormatException,
    );
    expect(
      () => McpServerConfig.fromJson(<String, Object?>{
        ...remoteServer().toJson(),
        'transport': 'websocket',
      }),
      throwsFormatException,
    );
    expect(
      () => McpServerConfig.fromJson(<String, Object?>{
        'id': 'local',
        'name': 'local',
        'transport': 'stdio',
        'command': 'uvx',
        'arguments': 'server-name',
      }),
      throwsFormatException,
    );
  });

  test('OAuth 认证配置按原语义持久化，缺省仍是固定请求头', () {
    final McpServerConfig plain = remoteServer();
    expect(
      (plain.endpoint as McpRemoteEndpoint).auth,
      McpRemoteAuth.headers,
    );
    expect(McpServerConfig.fromJson(plain.toJson()).toJson(), plain.toJson());

    final McpServerConfig oauth = McpServerConfig(
      id: 'oauth',
      name: '云端服务',
      endpoint: McpRemoteEndpoint(
        kind: McpTransportKind.streamableHttp,
        url: Uri.parse('https://mcp.example/mcp'),
        auth: McpRemoteAuth.oauth,
        oauth: McpOAuthClient(
          clientId: 'client-1',
          clientSecret: 'secret-1',
          scopes: const <String>['tools:read'],
          callbackPort: 18080,
        ),
      ),
    );
    final McpServerConfig round = McpServerConfig.fromJson(oauth.toJson());
    expect(round.toJson(), oauth.toJson());
    final McpRemoteEndpoint endpoint = round.endpoint as McpRemoteEndpoint;
    expect(endpoint.oauthClient!.clientId, 'client-1');
    expect(endpoint.oauthClient!.scopes, <String>['tools:read']);
    expect(endpoint.oauthClient!.callbackPort, 18080);
  });

  test('OAuth 只允许 Streamable HTTP，且不接受会覆盖令牌的 Authorization 头', () {
    expect(
      () => McpRemoteEndpoint(
        kind: McpTransportKind.sse,
        url: Uri.parse('https://mcp.example/sse'),
        auth: McpRemoteAuth.oauth,
        oauth: McpOAuthClient(),
      ),
      throwsFormatException,
    );
    expect(
      () => McpRemoteEndpoint(
        kind: McpTransportKind.streamableHttp,
        url: Uri.parse('https://mcp.example/mcp'),
        auth: McpRemoteAuth.oauth,
        oauth: McpOAuthClient(),
        headers: const <String, String>{'Authorization': 'Bearer stale'},
      ),
      throwsFormatException,
    );
    expect(
      () => McpRemoteEndpoint(
        kind: McpTransportKind.streamableHttp,
        url: Uri.parse('https://mcp.example/mcp'),
        auth: McpRemoteAuth.oauth,
      ),
      throwsFormatException,
    );
    expect(() => McpOAuthClient(callbackPort: 80), throwsFormatException);
    expect(
      () => McpServerConfig.fromJson(<String, Object?>{
        ...remoteServer().toJson(),
        'auth': 'mtls',
      }),
      throwsFormatException,
    );
  });

  test('改动授权目标会丢弃旧令牌，删除服务器会一并清掉', () {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);
    final McpServerConfig server = remoteServer();
    settings.saveMcpServer(server);

    void store(String accessToken) {
      unawaited(
        settings.mcpAuth.saveTokenSet(
          server.id,
          McpOAuthTokenSet(
            accessToken: accessToken,
            issuer: 'https://auth.example',
            resource: Uri.parse('https://mcp.example/mcp'),
          ),
        ),
      );
    }

    store('first');
    expect(settings.mcpAuth.tokenSet(server.id)!.accessToken, 'first');

    // 只改权限不该动令牌。
    settings.saveMcpServer(server.copyWith(permission: ToolPermission.denied));
    expect(settings.mcpAuth.tokenSet(server.id), isNotNull);

    // 换地址等于换了授权目标。
    settings.saveMcpServer(
      McpServerConfig(
        id: server.id,
        name: server.name,
        endpoint: McpRemoteEndpoint(
          kind: McpTransportKind.streamableHttp,
          url: Uri.parse('https://other.example/mcp'),
        ),
      ),
    );
    expect(settings.mcpAuth.tokenSet(server.id), isNull);

    store('second');
    settings.removeMcpServer(server.id);
    expect(settings.mcpAuth.tokenSet(server.id), isNull);
  });

  test('令牌随设置落盘并能重新读出', () async {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);
    await settings.mcpAuth.saveTokenSet(
      'server-a',
      McpOAuthTokenSet(
        accessToken: 'token',
        refreshToken: 'refresh',
        expiresAt: DateTime.utc(2026),
        issuer: 'https://auth.example',
        resource: Uri.parse('https://mcp.example/mcp'),
        clientId: 'client-1',
        scope: 'tools',
      ),
    );
    // 损坏或结构不完整的记录按未登录处理，不影响其它记录。
    final Map<String, Object?> json = settings.toJson();
    (json['mcpAuth']! as Map<String, Object?>)['broken'] = <String, Object?>{
      'accessToken': '',
    };
    final Directory dir = await Directory.systemTemp.createTemp('wepchat-mcp');
    addTearDown(() => dir.delete(recursive: true));
    final SettingsStore store = SettingsStore.atPath('${dir.path}/settings.json');
    await store.write(json);
    final AppSettings reloaded = AppSettings.load(store);
    addTearDown(reloaded.dispose);
    final McpOAuthTokenSet? token = reloaded.mcpAuth.tokenSet('server-a');
    expect(token, isNotNull);
    expect(token!.refreshToken, 'refresh');
    expect(token.expiresAt, DateTime.utc(2026));
    expect(token.clientId, 'client-1');
    expect(reloaded.mcpAuth.tokenSet('broken'), isNull);
  });

  test('拒绝 URL 凭据、非法请求头与无效超时', () {
    expect(
      () => McpRemoteEndpoint(
        kind: McpTransportKind.streamableHttp,
        url: Uri.parse('https://user:password@mcp.example/mcp'),
      ),
      throwsFormatException,
    );
    expect(
      () => McpRemoteEndpoint(
        kind: McpTransportKind.sse,
        url: Uri.parse('https://mcp.example/sse'),
        headers: const <String, String>{
          'Authorization': 'value\r\nInjected: yes',
        },
      ),
      throwsFormatException,
    );
    expect(
      () => McpServerConfig.fromJson(<String, Object?>{
        ...remoteServer().toJson(),
        'timeoutSeconds': 0,
      }),
      throwsFormatException,
    );
  });
}
