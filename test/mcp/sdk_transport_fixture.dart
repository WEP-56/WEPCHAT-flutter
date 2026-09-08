import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

/// In-memory JSON-RPC peer: no network, native runtime or API credentials.
class ScriptedMcpTransport extends sdk.Transport {
  final Completer<void> callStarted = Completer<void>();
  final List<String> methods = <String>[];
  bool stallCalls = false;
  bool malformedResult = false;
  bool closed = false;
  int pages = 0;

  @override
  String? get sessionId => null;

  @override
  Future<void> start() async {}

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    onclose?.call();
  }

  @override
  Future<void> send(sdk.JsonRpcMessage message, {int? relatedRequestId}) async {
    if (message is sdk.JsonRpcNotification) {
      methods.add(message.method);
      return;
    }
    if (message is! sdk.JsonRpcRequest) return;
    methods.add(message.method);
    final Map<String, Object?> result;
    switch (message.method) {
      case 'server/discover':
        _reply(
          message,
          error: const <String, Object?>{
            'code': -32601,
            'message': 'legacy peer',
          },
        );
        return;
      case 'initialize':
        result = const <String, Object?>{
          'protocolVersion': '2025-11-25',
          'capabilities': <String, Object?>{'tools': <String, Object?>{}},
          'serverInfo': <String, Object?>{'name': 'fixture', 'version': '1'},
        };
      case 'tools/list':
        pages++;
        result = <String, Object?>{
          'tools': <Object?>[
            <String, Object?>{
              'name': pages == 1 ? 'echo' : 'second',
              'inputSchema': <String, Object?>{
                'type': 'object',
                'properties': <String, Object?>{
                  'path': <String, Object?>{
                    'type': <String>['string', 'null'],
                  },
                  'items': <String, Object?>{
                    'type': 'array',
                    'items': <String, Object?>{'type': 'integer'},
                  },
                },
                'required': <String>['path'],
                'additionalProperties': false,
              },
            },
          ],
          if (pages == 1) 'nextCursor': 'next',
        };
      case 'tools/call':
        if (!callStarted.isCompleted) callStarted.complete();
        if (stallCalls) return;
        result = malformedResult
            ? <String, Object?>{'content': 'not-an-array'}
            : <String, Object?>{
                'content': <Object?>[
                  <String, Object?>{'type': 'text', 'text': '完成'},
                ],
                'structuredContent': <String, Object?>{'count': 2},
              };
      default:
        result = const <String, Object?>{};
    }
    _reply(message, result: result);
  }

  void _reply(
    sdk.JsonRpcRequest request, {
    Map<String, Object?>? result,
    Map<String, Object?>? error,
  }) {
    onmessage?.call(
      sdk.JsonRpcMessage.fromJson(<String, Object?>{
        'jsonrpc': '2.0',
        'id': request.id,
        if (error != null) 'error': error else 'result': result,
      }),
    );
  }
}
