import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/mcp/mcp_config.dart';
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
