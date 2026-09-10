// The legacy transport is selected explicitly in Advanced settings.
// ignore_for_file: deprecated_member_use
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../mcp/mcp_config.dart';
import '../mcp/mcp_connection.dart';
import '../mcp/mcp_oauth.dart';
import '../mcp/mcp_oauth_provider.dart';
import '../mcp/no_replay_http_transport.dart';
import '../mcp/sdk_mcp_connection.dart';
import 'mcp_windows_stdio.dart';

bool get supportsLocalMcp => Platform.isWindows;

/// OAuth 端点的跨域策略：只放行 HTTPS 授权服务器。
///
/// 受保护资源与授权服务器不同源是常态（例如 MCP 在 `mcp.example.com`、授权
/// 在 `auth.example.com`），规范也要求支持跨域发现。让用户确认具体域名是界面
/// 的责任——传输层不做交互，所以这里只做协议级的"必须是 HTTPS"判断。
bool allowHttpsOAuthEndpoint(Uri uri, sdk.OAuthEndpointKind endpointKind) =>
    uri.scheme == 'https';

/// 远端 transport 的唯一构建入口。
///
/// 聊天轮次与「登录授权」共用这一份实现：请求头、重连策略和 OAuth 挂载点
/// 不会出现两套配置。
sdk.Transport buildRemoteTransport(
  McpRemoteEndpoint endpoint, {
  sdk.OAuthClientProvider? authProvider,
}) {
  if (endpoint.kind == McpTransportKind.sse) {
    if (authProvider != null) {
      throw const McpFailure('SSE 传输不支持 OAuth 登录，请使用固定请求头');
    }
    return sdk.SseClientTransport(
      endpoint.url,
      opts: sdk.SseClientTransportOptions(headers: endpoint.headers),
    );
  }
  return NoReplayHttpTransport(
    endpoint.url,
    opts: sdk.StreamableHttpClientTransportOptions(
      authProvider: authProvider,
      oauthUriValidator: authProvider == null ? null : allowHttpsOAuthEndpoint,
      requestInit: endpoint.headers.isEmpty
          ? null
          : <String, Object?>{'headers': endpoint.headers},
      reconnectionOptions: const sdk.StreamableHttpReconnectionOptions(
        maxReconnectionDelay: 1000,
        initialReconnectionDelay: 1000,
        reconnectionDelayGrowFactor: 1,
        maxRetries: 0,
      ),
    ),
  );
}

/// Platform capability checks are enforced here even when configuration was
/// written externally. Android never reaches a subprocess implementation.
McpConnection createMcpConnection(
  McpServerConfig server,
  McpConnectionContext context,
) {
  final sdk.Transport transport = switch (server.endpoint) {
    final McpRemoteEndpoint endpoint => buildRemoteTransport(
      endpoint,
      authProvider: _sessionAuthProvider(server, endpoint, context.authStore),
    ),
    final McpStdioEndpoint endpoint => _stdioTransport(
      endpoint,
      context.workspaceRoot,
    ),
  };
  return SdkMcpConnection(server: server, transport: transport);
}

/// 聊天轮次用的 OAuth provider：只读令牌与刷新，绝不发起浏览器跳转。
sdk.OAuthClientProvider? _sessionAuthProvider(
  McpServerConfig server,
  McpRemoteEndpoint endpoint,
  McpAuthStore authStore,
) {
  final McpOAuthClient? client = endpoint.oauthClient;
  if (client == null) return null;
  return McpTokenOnlyProvider(
    tokens: McpTokenSource(
      serverId: server.id,
      client: client,
      store: authStore,
    ),
  );
}

sdk.Transport _stdioTransport(
  McpStdioEndpoint endpoint,
  String? workspaceRoot,
) {
  if (!supportsLocalMcp) {
    throw const McpFailure('当前平台不支持 stdio MCP；请使用网络服务器');
  }
  return WindowsMcpStdioTransport(endpoint, workspaceRoot: workspaceRoot);
}
