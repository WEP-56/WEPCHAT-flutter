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
    if (index < 0) {
      servers.add(server);
    } else {
      servers[index] = server;
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
    _changed();
  }
}
