import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_config.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/platform/mcp_transports.dart';

/// Local protocol integration only. Run explicitly; no external server or key.
void main() {
  test('失效的 HTTP 会话不会触发 SDK 自动重发工具调用', () async {
    final HttpServer server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      0,
    );
    int initialized = 0;
    int calls = 0;
    final subscription = server.listen((HttpRequest request) async {
      if (request.method != 'POST') {
        request.response.statusCode = HttpStatus.methodNotAllowed;
        await request.response.close();
        return;
      }
      final Map<String, Object?> body =
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, Object?>;
      final Object? id = body['id'];
      if (id == null) {
        request.response.statusCode = HttpStatus.accepted;
        await request.response.close();
        return;
      }
      final Map<String, Object?> response = <String, Object?>{
        'jsonrpc': '2.0',
        'id': id,
      };
      switch (body['method']) {
        case 'server/discover':
          response['error'] = <String, Object?>{
            'code': -32601,
            'message': 'legacy peer',
          };
        case 'initialize':
          initialized++;
          request.response.headers.set('Mcp-Session-Id', 'fixture-session');
          response['result'] = <String, Object?>{
            'protocolVersion': '2025-11-25',
            'capabilities': <String, Object?>{'tools': <String, Object?>{}},
            'serverInfo': <String, Object?>{'name': 'fixture', 'version': '1'},
          };
        case 'tools/list':
          response['result'] = <String, Object?>{
            'tools': <Object?>[
              <String, Object?>{
                'name': 'write',
                'inputSchema': <String, Object?>{'type': 'object'},
              },
            ],
          };
        case 'tools/call':
          calls++;
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
          return;
      }
      request.response.headers.contentType = ContentType.json;
      request.response.write(jsonEncode(response));
      await request.response.close();
    });
    final McpConnection connection = createMcpConnection(
      McpServerConfig(
        id: 'fixture',
        name: 'fixture',
        endpoint: McpRemoteEndpoint(
          kind: McpTransportKind.streamableHttp,
          url: Uri.parse('http://127.0.0.1:${server.port}/mcp'),
        ),
        timeout: const Duration(seconds: 5),
      ),
      null,
    );
    try {
      await connection.connect(CancellationToken.none);
      await expectLater(
        connection.call('write', <String, Object?>{}, CancellationToken.none),
        throwsA(isA<McpFailure>()),
      );
      expect(calls, 1);
      expect(initialized, 1);
    } finally {
      await connection.close();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
}
