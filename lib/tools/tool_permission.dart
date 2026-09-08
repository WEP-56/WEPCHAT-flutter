/// Execution policy shared by built-in tools and external MCP servers.
enum ToolPermission {
  denied('禁止'),
  ask('询问'),
  allowed('允许');

  const ToolPermission(this.label);

  final String label;
}
