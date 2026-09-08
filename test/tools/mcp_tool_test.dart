import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/mcp/mcp_session.dart';
import 'package:wepchat/platform/workspace_guard.dart';
import 'package:wepchat/state/app_settings.dart';
import 'package:wepchat/tools/mcp_tool.dart';
import 'package:wepchat/tools/permission_gate.dart';
import 'package:wepchat/tools/tool.dart';
import 'package:wepchat/tools/tool_permission.dart';
import 'package:wepchat/tools/tool_registry.dart';
import 'package:wepchat/tools/workspace/mutation_queue.dart';
import 'package:wepchat/tools/workspace/write_file_tool.dart';

import '../mcp/mcp_test_support.dart';

void main() {
  late AppSettings settings;
  late FakeMcpConnection connection;
  late CancellationTokenSource source;
  late McpToolAdapter tool;
  late ToolRegistry registry;
  late ToolContext context;

  setUp(() {
    settings = AppSettings.memory();
    settings.saveMcpServer(remoteServer());
    settings.setMcpEnabled(true);
    settings.setPermission('write_file', ToolPermission.allowed);
    connection = FakeMcpConnection();
    source = CancellationTokenSource();
    tool = McpToolAdapter(
      McpToolBinding(
        server: remoteServer(),
        tool: fakeMcpTool(),
        connection: connection,
        token: source.token,
      ),
    );
    registry = ToolRegistry(<Tool>[
      tool,
      const WriteFileTool(),
    ], gate: PermissionGate(settings: settings));
    context = ToolContext(
      sessionId: 'test-session',
      callId: 'call-1',
      workspace: WorkspaceGuard(Directory.systemTemp.path),
      token: source.token,
    );
  });
  tearDown(() => settings.dispose());

  test('MCP 路径按外部协议转交，内置文件工具仍拒绝越界', () async {
    const Map<String, Object?> arguments = <String, Object?>{
      'path': '../outside.txt',
      'content': 'test',
    };
    expect(
      (await registry.dispatch(tool.name, arguments, context)).outcome,
      ToolOutcome.ok,
    );
    expect(connection.lastArguments, arguments);
    expect(
      (await registry.dispatch('write_file', arguments, context)).outcome,
      ToolOutcome.failed,
    );
  });

  test('关闭 MCP 或拒绝权限后，旧工具声明也不能执行', () async {
    settings.setMcpEnabled(false);
    expect(
      (await registry.dispatch(
        tool.name,
        const <String, Object?>{},
        context,
      )).outcome,
      ToolOutcome.denied,
    );
    settings.setMcpEnabled(true);
    settings.saveMcpServer(remoteServer(permission: ToolPermission.denied));
    expect(
      (await registry.dispatch(
        tool.name,
        const <String, Object?>{},
        context,
      )).outcome,
      ToolOutcome.denied,
    );
    expect(connection.calls, 0);
  });

  test('外部参数验证失败时不请求服务器', () async {
    final McpToolAdapter invalid = McpToolAdapter(
      McpToolBinding(
        server: remoteServer(),
        tool: fakeMcpTool(validator: (_) async => '参数类型不正确'),
        connection: connection,
        token: source.token,
      ),
    );
    final ToolRegistry validating = ToolRegistry(<Tool>[
      invalid,
    ], gate: PermissionGate(settings: settings));
    expect(
      (await validating.dispatch(
        invalid.name,
        const <String, Object?>{},
        context,
      )).outcome,
      ToolOutcome.failed,
    );
    expect(connection.calls, 0);
  });

  test('排队中的 MCP 调用取消后不再发送', () async {
    final Completer<void> release = Completer<void>();
    final Future<void> blocker = MutationQueue.instance.run(
      context.workspace.root,
      () => release.future,
    );
    final Future<ToolResult> pending = registry.dispatch(
      tool.name,
      const <String, Object?>{},
      context,
    );
    source.cancel();
    release.complete();
    await blocker;
    expect((await pending).outcome, ToolOutcome.cancelled);
    expect(connection.calls, 0);
  });

  test('外部业务失败保持失败状态', () async {
    connection.onCall = (_) async =>
        const McpReply(text: '外部服务拒绝操作', isError: true);
    expect(
      (await registry.dispatch(
        tool.name,
        const <String, Object?>{},
        context,
      )).outcome,
      ToolOutcome.failed,
    );
  });

  test('命名空间稳定，支持重名及非 ASCII 工具名', () {
    final String a = mcpToolName('a', '查询/内容');
    expect(a, mcpToolName('a', '查询/内容'));
    expect(a, isNot(mcpToolName('b', '查询/内容')));
    expect(a.length, lessThanOrEqualTo(64));
    expect(RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(a), isTrue);
  });
}
