import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_auth_storage.dart';
import 'package:wepchat/mcp/mcp_config.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/tools/tool_permission.dart';

/// 建立连接所需的宿主上下文，默认使用内存令牌存储。
McpConnectionContext mcpContext({
  String? workspaceRoot,
  McpAuthStorage? authStore,
}) => (
  workspaceRoot: workspaceRoot,
  authStore: authStore ?? McpAuthStorage(),
);

McpServerConfig remoteServer({
  String id = 'server-a',
  ToolPermission permission = ToolPermission.allowed,
}) => McpServerConfig(
  id: id,
  name: id,
  endpoint: McpRemoteEndpoint(
    kind: McpTransportKind.streamableHttp,
    url: Uri.parse('https://mcp.example/mcp'),
  ),
  permission: permission,
);

McpToolInfo fakeMcpTool({
  String name = 'echo',
  McpArgumentValidator? validator,
}) => McpToolInfo(
  name: name,
  description: 'Test tool',
  inputSchema: const <String, Object?>{'type': 'object'},
  validateArguments: validator ?? (_) async => null,
);

class FakeMcpConnection implements McpConnection {
  int connects = 0;
  int calls = 0;
  int closes = 0;
  Map<String, Object?>? lastArguments;
  Future<List<McpToolInfo>> Function(CancellationToken)? onConnect;
  Future<McpReply> Function(CancellationToken)? onCall;
  Future<void> Function()? onClose;

  @override
  Future<List<McpToolInfo>> connect(CancellationToken token) async {
    connects++;
    token.throwIfCancelled();
    return onConnect == null
        ? <McpToolInfo>[fakeMcpTool()]
        : await onConnect!(token);
  }

  @override
  Future<McpReply> call(
    String name,
    Map<String, Object?> arguments,
    CancellationToken token,
  ) async {
    calls++;
    token.throwIfCancelled();
    lastArguments = arguments;
    return onCall == null ? const McpReply(text: 'done') : await onCall!(token);
  }

  @override
  Future<void> close() async {
    closes++;
    await onClose?.call();
  }
}
