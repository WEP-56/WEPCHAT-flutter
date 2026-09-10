// Legacy HTTP+SSE is an explicit user-selected compatibility transport.
// ignore_for_file: deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../core/cancellation_token.dart';
import '../core/redact.dart';
import 'mcp_config.dart';
import 'mcp_connection.dart';
import 'mcp_error_text.dart';
import 'mcp_result_text.dart';

/// Adapts the MCP SDK at the infrastructure boundary. A disconnected call is
/// never replayed by this adapter: the server may already have applied it.
final class SdkMcpConnection implements McpConnection {
  SdkMcpConnection({required this.server, required sdk.Transport transport})
    : _transport = transport,
      _client = sdk.McpClient(
        const sdk.Implementation(name: 'wepchat', version: '1'),
        options: sdk.McpClientOptions(
          protocol: server.endpoint.kind == McpTransportKind.sse
              ? sdk.McpProtocol.legacy
              : sdk.McpProtocol.stable,
          capabilities: const sdk.ClientCapabilities(),
          gracefulShutdownTimeout: const Duration(seconds: 2),
        ),
      ) {
    // SDK diagnostics can contain response bodies and authentication data.
    // Failures are reported through our contextual result channel instead.
    sdk.silenceMcpLogs();
    _client.onerror = (Error error) {
      _protocolError = _safeError(error);
    };
  }

  final McpServerConfig server;
  final sdk.Transport _transport;
  final sdk.McpClient _client;
  String? _protocolError;
  bool _closed = false;
  Future<void>? _closing;

  @override
  Future<List<McpToolInfo>> connect(CancellationToken token) async {
    token.throwIfCancelled();
    final Completer<void> cancelled = Completer<void>();
    final void Function() unregister = token.onCancel(() {
      if (!cancelled.isCompleted) cancelled.complete();
    });
    try {
      await Future.any<void>(<Future<void>>[
        _client.connect(_transport),
        cancelled.future.then<void>((_) => throw const CancelledException()),
      ]).timeout(server.timeout);
      token.throwIfCancelled();
      _protocolError = null;
      final List<McpToolInfo> tools = <McpToolInfo>[];
      final Set<String> names = <String>{};
      final Set<String> cursors = <String>{};
      String? cursor;
      do {
        final sdk.ListToolsResult page = await _request(
          token,
          (sdk.RequestOptions options) => _client.listTools(
            params: sdk.ListToolsRequest(cursor: cursor),
            options: options,
          ),
        );
        for (final sdk.Tool tool in page.tools) {
          if (!names.add(tool.name)) {
            throw const McpFailure('服务器返回了重复的工具名');
          }
          final Map<String, Object?> schema = tool.inputSchema.toJson();
          if (utf8.encode(jsonEncode(schema)).length > kMcpMaxSchemaBytes) {
            throw const McpFailure('服务器的工具参数声明过大');
          }
          tools.add(
            McpToolInfo(
              name: tool.name,
              description: tool.description ?? tool.title ?? tool.name,
              inputSchema: schema,
              validateArguments: (Map<String, Object?> arguments) =>
                  _validateSchema(schema, arguments, token, server.timeout),
            ),
          );
        }
        if (tools.length > kMcpMaxTools) {
          throw const McpFailure('服务器工具数量超过 256 个');
        }
        cursor = page.nextCursor;
        if (cursor != null && cursors.length + 1 >= kMcpMaxToolPages) {
          throw const McpFailure('服务器工具分页超过上限');
        }
        if (cursor != null && !cursors.add(cursor)) {
          throw const McpFailure('服务器返回了重复的工具分页游标');
        }
      } while (cursor != null);
      return List<McpToolInfo>.unmodifiable(tools);
    } on CancelledException {
      rethrow;
    } on Object catch (error) {
      if (token.isCancelled) throw const CancelledException();
      throw McpFailure('MCP「${server.name}」连接或发现工具失败：${_safeError(error)}');
    } finally {
      unregister();
    }
  }

  @override
  Future<McpReply> call(
    String name,
    Map<String, Object?> arguments,
    CancellationToken token,
  ) async {
    token.throwIfCancelled();
    if (_closed || !_client.isConnected) {
      throw McpFailure('MCP「${server.name}」连接已关闭，请开始新一轮对话重新连接');
    }
    _protocolError = null;
    try {
      final sdk.CallToolResult result = await _request(
        token,
        (sdk.RequestOptions options) => _client.callTool(
          sdk.CallToolRequest(name: name, arguments: arguments),
          options: options,
        ),
      );
      return mcpResultText(result);
    } on Object catch (error) {
      if (token.isCancelled || error is sdk.AbortError) {
        throw const CancelledException();
      }
      throw McpFailure(
        'MCP「${server.name}」调用 $name 失败：${_safeError(error)}。'
        '服务器可能已执行操作，请勿自动重试有副作用的调用。',
      );
    }
  }

  Future<T> _request<T>(
    CancellationToken token,
    Future<T> Function(sdk.RequestOptions options) send,
  ) async {
    token.throwIfCancelled();
    final sdk.BasicAbortController abort = sdk.BasicAbortController();
    final void Function() unregister = token.onCancel(abort.abort);
    try {
      return await send(
        sdk.RequestOptions(
          signal: abort.signal,
          timeout: server.timeout,
          maxTotalTimeout: server.timeout,
        ),
      );
    } finally {
      unregister();
      // The SDK has removed the completed request's listener by this point.
      abort.abort('request finished');
    }
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      try {
        await _client.close();
      } finally {
        // Also release a transport whose start failed before Protocol attached it.
        await _transport.close();
      }
    } on Object catch (error) {
      throw McpFailure('MCP「${server.name}」关闭失败：${_safeError(error)}');
    }
  }

  /// OAuth 端点的 401 含义与固定请求头不同：不是"凭据填错了"，而是"该登录了"。
  bool get _usesOAuth => switch (server.endpoint) {
    final McpRemoteEndpoint endpoint => endpoint.oauthClient != null,
    McpStdioEndpoint() => false,
  };

  String _safeError(Object error) => mcpErrorText(
    error,
    oauthEndpoint: _usesOAuth,
    fallback: _protocolError ?? '连接中断或服务器响应无效',
  );
}

Future<String?> _validateSchema(
  Map<String, Object?> schema,
  Map<String, Object?> arguments,
  CancellationToken token,
  Duration timeout,
) async {
  token.throwIfCancelled();
  final ReceivePort replies = ReceivePort();
  final void Function() unregister = token.onCancel(() {
    replies.sendPort.send(const _SchemaCancelled());
  });
  Isolate? worker;
  try {
    worker = await Isolate.spawn(
      _validateSchemaInWorker,
      _SchemaRequest(schema, arguments, replies.sendPort),
      onError: replies.sendPort,
      errorsAreFatal: true,
    );
    final Object? reply = await replies.first.timeout(timeout);
    token.throwIfCancelled();
    return switch (reply) {
      _SchemaResult(:final message) => message,
      _SchemaCancelled() => throw const CancelledException(),
      _ => throw const McpFailure('MCP 参数校验进程失败'),
    };
  } on TimeoutException {
    throw const McpFailure('MCP 参数校验超时');
  } finally {
    unregister();
    worker?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

final class _SchemaRequest {
  const _SchemaRequest(this.schema, this.arguments, this.reply);
  final Map<String, Object?> schema;
  final Map<String, Object?> arguments;
  final SendPort reply;
}

final class _SchemaResult {
  const _SchemaResult(this.message);
  final String? message;
}

final class _SchemaCancelled {
  const _SchemaCancelled();
}

void _validateSchemaInWorker(_SchemaRequest request) {
  String? message;
  try {
    sdk.JsonSchema.fromJson(request.schema).validate(request.arguments);
  } on sdk.JsonSchemaValidationException catch (error) {
    message = '参数不符合服务器声明：${redact(error.toString())}';
  } on FormatException {
    message = '服务器的参数声明无效';
  }
  Isolate.exit(request.reply, _SchemaResult(message));
}
