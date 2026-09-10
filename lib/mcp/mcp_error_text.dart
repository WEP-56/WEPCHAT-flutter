// The legacy SSE error type stays in the mapping so an explicitly selected
// legacy transport still reports its status code.
// ignore_for_file: deprecated_member_use
import 'dart:async';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import 'mcp_connection.dart';
import 'no_replay_http_transport.dart';

/// MCP 错误到用户文案的唯一映射入口。
///
/// 对话连接和「登录授权」都从这里取文案，避免同一个失败出现两种说法。底层不
/// 在这里弹窗，只负责把错误翻译成可诊断的一句话。
String mcpErrorText(
  Object error, {
  String fallback = '连接中断或服务器响应无效',
  bool oauthEndpoint = false,
}) {
  if (error is TimeoutException) return '请求超时';
  if (error is McpSessionExpired) return '服务器会话已失效，请在新一轮中重新连接';
  if (error is McpFailure) return error.message;
  if (error is sdk.UnauthorizedError) {
    return oauthEndpoint
        ? 'OAuth 授权未完成或已失效，请在设置中重新登录'
        : '认证失败，请检查请求头中的凭据';
  }
  if (error is sdk.StreamableHttpError && error.code != null) {
    return '服务器返回 HTTP ${error.code}';
  }
  if (error is sdk.SseClientError && error.code != null) {
    return '服务器返回 HTTP ${error.code}';
  }
  if (error is sdk.McpError) {
    return error.code == sdk.ErrorCode.requestTimeout.value
        ? '请求超时'
        : '协议错误 ${error.code}';
  }
  if (error is FormatException) return '服务器返回的数据格式无效';
  return fallback;
}
