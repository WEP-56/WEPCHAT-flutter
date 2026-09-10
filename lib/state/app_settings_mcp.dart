part of 'app_settings.dart';

/// Advanced configuration is persisted through the same settings store.
extension McpAppSettings on AppSettings {
  void setMcpEnabled(bool enabled) {
    if (_mcp.enabled == enabled) return;
    _mcp = McpSettings(enabled: enabled, servers: _mcp.servers);
    _changed();
  }

  void saveMcpServer(McpServerConfig server) {
    final List<McpServerConfig> servers = List<McpServerConfig>.of(
      _mcp.servers,
    );
    final int index = servers.indexWhere(
      (McpServerConfig s) => s.id == server.id,
    );
    final McpServerConfig? previous = index < 0 ? null : servers[index];
    if (index < 0) {
      servers.add(server);
    } else {
      servers[index] = server;
    }
    // 授权目标变了（地址、传输方式或客户端标识）旧令牌就作废：继续拿它去请求
    // 一个已经换掉的服务器只会得到一个无法解释的 401。
    if (previous != null && !_sameAuthorizationTarget(previous, server)) {
      mcpAuth.remove(server.id);
    }
    _mcp = McpSettings(enabled: _mcp.enabled, servers: servers);
    _changed();
  }

  void removeMcpServer(String id) {
    if (_mcp.server(id) == null) {
      throw ArgumentError.value(id, 'id', 'MCP server 不存在');
    }
    _mcp = McpSettings(
      enabled: _mcp.enabled,
      servers: _mcp.servers.where((McpServerConfig server) => server.id != id),
    );
    // 服务器没了，它的 OAuth 令牌也不该继续留在磁盘上。
    mcpAuth.remove(id);
    _changed();
  }
}

bool _sameAuthorizationTarget(McpServerConfig a, McpServerConfig b) {
  final McpEndpoint first = a.endpoint;
  final McpEndpoint second = b.endpoint;
  if (first is! McpRemoteEndpoint || second is! McpRemoteEndpoint) {
    return first.kind == second.kind;
  }
  return first.kind == second.kind &&
      first.url == second.url &&
      first.auth == second.auth &&
      first.oauthClient?.clientId == second.oauthClient?.clientId;
}
