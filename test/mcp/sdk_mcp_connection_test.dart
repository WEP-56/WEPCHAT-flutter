import 'package:flutter_test/flutter_test.dart';
import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_config.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/mcp/mcp_result_text.dart';
import 'package:wepchat/mcp/sdk_mcp_connection.dart';

import 'mcp_test_support.dart';
import 'sdk_transport_fixture.dart';

void main() {
  late ScriptedMcpTransport transport;
  late SdkMcpConnection connection;

  setUp(() {
    transport = ScriptedMcpTransport();
    final McpServerConfig server = remoteServer();
    connection = SdkMcpConnection(
      server: McpServerConfig(
        id: server.id,
        name: server.name,
        endpoint: server.endpoint,
        timeout: const Duration(seconds: 1),
      ),
      transport: transport,
    );
  });
  tearDown(() => connection.close());

  test('握手、分页发现和外部 JSON Schema 验证', () async {
    final List<McpToolInfo> tools = await connection.connect(
      CancellationToken.none,
    );
    expect(tools.map((McpToolInfo tool) => tool.name), <String>[
      'echo',
      'second',
    ]);
    expect(transport.methods, contains('notifications/initialized'));
    expect(
      await tools.first.validateArguments(<String, Object?>{
        'path': null,
        'items': <int>[1, 2],
      }),
      isNull,
    );
    expect(
      await tools.first.validateArguments(<String, Object?>{
        'path': 'a',
        'items': <String>['wrong'],
      }),
      isNotNull,
    );
    expect(
      await tools.first.validateArguments(<String, Object?>{
        'path': 'a',
        'extra': true,
      }),
      isNotNull,
    );
  });

  test('文本与结构化结果均保留', () async {
    await connection.connect(CancellationToken.none);
    final McpReply result = await connection.call('echo', <String, Object?>{
      'path': 'a',
    }, CancellationToken.none);
    expect(result.isError, isFalse);
    expect(result.text, contains('完成'));
    expect(result.text, contains('"count":2'));
  });

  test('会话取消后不再启动参数校验', () async {
    final CancellationTokenSource source = CancellationTokenSource();
    final List<McpToolInfo> tools = await connection.connect(source.token);
    source.cancel();
    await expectLater(
      tools.first.validateArguments(<String, Object?>{'path': 'a'}),
      throwsA(isA<CancelledException>()),
    );
  });

  test('取消传到 MCP 请求，不等待服务器返回', () async {
    await connection.connect(CancellationToken.none);
    transport.stallCalls = true;
    final CancellationTokenSource source = CancellationTokenSource();
    final Future<void> expectation = expectLater(
      connection.call('echo', <String, Object?>{'path': 'a'}, source.token),
      throwsA(isA<CancelledException>()),
    );
    await transport.callStarted.future;
    source.cancel();
    await expectation;
    expect(
      transport.methods.where((String method) => method == 'tools/call').length,
      1,
    );
  });

  test('超时和响应错误不会变成空成功结果', () async {
    await connection.connect(CancellationToken.none);
    transport.malformedResult = true;
    await expectLater(
      connection.call('echo', <String, Object?>{
        'path': 'a',
      }, CancellationToken.none),
      throwsA(isA<McpFailure>()),
    );
    transport.malformedResult = false;
    transport.stallCalls = true;
    await expectLater(
      connection.call('echo', <String, Object?>{
        'path': 'a',
      }, CancellationToken.none),
      throwsA(
        isA<McpFailure>().having(
          (McpFailure e) => e.message,
          'message',
          contains('超时'),
        ),
      ),
    );
  });

  test('二进制结果明确报告不支持并保留同次返回的文本', () {
    final McpReply result = mcpResultText(
      const sdk.CallToolResult(
        content: <sdk.Content>[
          sdk.TextContent(text: '文件已经生成'),
          sdk.ImageContent(data: 'AA==', mimeType: 'image/png'),
        ],
      ),
    );
    expect(result.isError, isTrue);
    expect(result.text, contains('文件已经生成'));
    expect(result.text, contains('图片'));
    expect(result.text, contains('不要'));
  });

  test('无错误正文也不能伪造成功说明', () {
    final McpReply result = mcpResultText(
      const sdk.CallToolResult(content: <sdk.Content>[], isError: true),
    );
    expect(result.isError, isTrue);
    expect(result.text, contains('失败'));
  });
}
