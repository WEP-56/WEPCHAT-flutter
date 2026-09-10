import '../core/cancellation_token.dart';
import '../tools/tool_permission.dart';
import 'mcp_config.dart';
import 'mcp_connection.dart';
import 'mcp_oauth.dart';

final class McpToolBinding {
  const McpToolBinding({
    required this.server,
    required this.tool,
    required this.connection,
    required this.token,
  });

  final McpServerConfig server;
  final McpToolInfo tool;
  final McpConnection connection;
  final CancellationToken token;
}

/// Owns an immutable tool snapshot and connections for one Agent run.
/// No connection or mutable server state is shared between conversations.
final class McpSession {
  McpSession({
    required Iterable<McpServerConfig> servers,
    required McpConnectionFactory factory,
    required CancellationToken parentToken,
    required this.supportsStdio,
    required McpAuthStore authStore,
    this.workspaceRoot,
    this.onDiscovered,
    this.onClosed,
  }) : _servers = List<McpServerConfig>.unmodifiable(servers),
       _factory = factory,
       _context = (workspaceRoot: workspaceRoot, authStore: authStore) {
    _unlinkParent = parentToken.onCancel(_source.cancel);
  }

  final List<McpServerConfig> _servers;
  final McpConnectionFactory _factory;
  final McpConnectionContext _context;
  final bool supportsStdio;
  final String? workspaceRoot;
  final void Function(McpServerConfig, List<McpToolInfo>)? onDiscovered;
  final void Function()? onClosed;
  final CancellationTokenSource _source = CancellationTokenSource();
  late final void Function() _unlinkParent;
  final List<McpConnection> _connections = <McpConnection>[];
  final List<McpToolBinding> _tools = <McpToolBinding>[];
  Future<void>? _closing;
  bool _initialized = false;

  List<McpToolBinding> get tools => List<McpToolBinding>.unmodifiable(_tools);

  Future<void> initialize() async {
    if (_initialized) throw StateError('MCP session 已经初始化');
    _initialized = true;
    for (final McpServerConfig server in _servers) {
      _source.token.throwIfCancelled();
      if (!supportsStdio && server.endpoint.kind == McpTransportKind.stdio) {
        throw McpFailure('MCP「${server.name}」使用 stdio，仅 Windows 支持；请禁用该服务器');
      }
      final McpConnection connection = _factory(server, _context);
      _connections.add(connection);
      final List<McpToolInfo> discovered = await connection.connect(
        _source.token,
      );
      _source.token.throwIfCancelled();
      if (_tools.length + discovered.length > kMcpMaxTools) {
        throw const McpFailure('本轮 MCP 工具总数超过 256 个，请减少启用的服务器');
      }
      _tools.addAll(
        discovered.map(
          (McpToolInfo tool) => McpToolBinding(
            server: server,
            tool: tool,
            connection: connection,
            token: _source.token,
          ),
        ),
      );
      onDiscovered?.call(server, discovered);
    }
  }

  void cancel() => _source.cancel();

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _source.cancel();
    _unlinkParent();
    final List<String> errors = <String>[];
    try {
      for (final McpConnection connection in _connections.reversed) {
        try {
          await connection.close();
        } on McpFailure catch (error) {
          errors.add(error.message);
        }
      }
    } finally {
      onClosed?.call();
    }
    if (errors.isNotEmpty) throw McpFailure(errors.join('\n'));
  }

  static Iterable<McpServerConfig> enabledServers(McpSettings settings) =>
      settings.enabled
      ? settings.servers.where(
          (McpServerConfig server) =>
              server.enabled && server.permission != ToolPermission.denied,
        )
      : const <McpServerConfig>[];
}
