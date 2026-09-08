import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../ai/provider_api.dart';
import '../core/cancellation_token.dart';
import '../mcp/mcp_connection.dart';
import '../mcp/mcp_session.dart';
import 'tool.dart';
import 'workspace/mutation_queue.dart';

/// An external MCP tool deliberately bypasses WorkspaceGuard. PermissionGate
/// still controls execution, and calls share the workspace mutation queue so
/// they cannot race the built-in file tools in the same conversation.
class McpToolAdapter extends Tool {
  McpToolAdapter(this.binding)
    : definition = ToolDefinition(
        name: mcpToolName(binding.server.id, binding.tool.name),
        description:
            'MCP「${binding.server.name}」/${binding.tool.name}：'
            '${binding.tool.description}\n由外部服务器执行，不受工作区门禁限制。',
        schema: binding.tool.inputSchema,
      );

  final McpToolBinding binding;

  @override
  final ToolDefinition definition;

  @override
  String get displayName => '${binding.server.name} / ${binding.tool.name}';

  @override
  String get permissionId => binding.server.permissionId;

  @override
  Future<String?> validateArguments(Map<String, Object?> arguments) =>
      binding.tool.validateArguments(arguments);

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) => MutationQueue.instance.run(context.workspace.root, () async {
    ToolResult result;
    try {
      context.token.throwIfCancelled();
      binding.token.throwIfCancelled();
      final McpReply reply = await binding.connection.call(
        binding.tool.name,
        arguments,
        binding.token,
      );
      result = ToolResult(
        content: reply.text,
        outcome: reply.isError ? ToolOutcome.failed : ToolOutcome.ok,
        uiPayload: <String, Object?>{
          'title': 'MCP · $displayName',
          'mcpServerId': binding.server.id,
        },
      );
    } on CancelledException {
      result = ToolResult.cancelled('MCP 调用已取消或配置已改变。外部服务器可能已执行操作，请勿自动重试。');
    } on McpFailure catch (error) {
      result = ToolResult.error(error.message);
    }
    // Correlation metadata only: never log arguments, headers or result bodies.
    // ignore: avoid_print
    print(
      '[mcp] ${jsonEncode(<String, Object?>{'sessionId': context.sessionId, 'callId': context.callId, 'serverId': binding.server.id, 'tool': binding.tool.name, 'outcome': result.outcome.name})}',
    );
    return result;
  });
}

/// Stable ASCII names satisfy provider constraints and separate equal names
/// from different servers. The original MCP name is retained in the binding.
String mcpToolName(String serverId, String toolName) {
  final String digest = sha256
      .convert(utf8.encode('$serverId\u0000$toolName'))
      .toString();
  final String readable = toolName.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
  final String prefix = readable.length > 24
      ? readable.substring(0, 24)
      : readable;
  return 'mcp_${digest.substring(0, 20)}_$prefix';
}
