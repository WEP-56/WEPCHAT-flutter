// The legacy transport is selected explicitly in Advanced settings.
// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../mcp/mcp_config.dart';
import '../mcp/mcp_connection.dart';
import '../mcp/no_replay_http_transport.dart';
import '../mcp/sdk_mcp_connection.dart';
import 'mcp_windows_stdio.dart';

bool get supportsLocalMcp => Platform.isWindows;

/// Platform capability checks are enforced here even when configuration was
/// written externally. Android never reaches a subprocess implementation.
McpConnection createMcpConnection(
  McpServerConfig server,
  String? workspaceRoot,
) {
  final sdk.Transport transport;
  switch (server.endpoint) {
    case McpRemoteEndpoint(:final Uri url, :final headers, :final kind):
      transport = kind == McpTransportKind.sse
          ? sdk.SseClientTransport(
              url,
              opts: sdk.SseClientTransportOptions(headers: headers),
            )
          : NoReplayHttpTransport(
              url,
              opts: sdk.StreamableHttpClientTransportOptions(
                requestInit: <String, Object?>{'headers': headers},
                reconnectionOptions:
                    const sdk.StreamableHttpReconnectionOptions(
                      maxReconnectionDelay: 1000,
                      initialReconnectionDelay: 1000,
                      reconnectionDelayGrowFactor: 1,
                      maxRetries: 0,
                    ),
              ),
            );
    case final McpStdioEndpoint endpoint:
      if (!supportsLocalMcp) {
        throw const McpFailure('当前平台不支持 stdio MCP；请使用网络服务器');
      }
      transport = WindowsMcpStdioTransport(
        endpoint,
        workspaceRoot: workspaceRoot,
      );
  }
  return SdkMcpConnection(server: server, transport: transport);
}
