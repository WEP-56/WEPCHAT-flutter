import '../core/cancellation_token.dart';
import '../core/errors.dart';
import 'mcp_config.dart';

typedef McpArgumentValidator =
    Future<String?> Function(Map<String, Object?> arguments);
typedef McpConnectionFactory =
    McpConnection Function(McpServerConfig server, String? workspaceRoot);

/// App-owned metadata; SDK types never enter the Agent/tool contract.
final class McpToolInfo {
  McpToolInfo({
    required this.name,
    required this.description,
    required Map<String, Object?> inputSchema,
    required this.validateArguments,
  }) : inputSchema = Map<String, Object?>.unmodifiable(inputSchema);

  final String name;
  final String description;
  final Map<String, Object?> inputSchema;
  final McpArgumentValidator validateArguments;
}

final class McpReply {
  const McpReply({required this.text, this.isError = false});
  final String text;
  final bool isError;
}

/// One connection belongs to one chat turn or explicit connection test.
/// Closing it must release its network streams and owned server process.
abstract interface class McpConnection {
  Future<List<McpToolInfo>> connect(CancellationToken token);
  Future<McpReply> call(
    String name,
    Map<String, Object?> arguments,
    CancellationToken token,
  );
  Future<void> close();
}

final class McpFailure extends WepError {
  const McpFailure(super.message);
}
