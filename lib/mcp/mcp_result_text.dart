import 'dart:convert';

import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../tools/truncate.dart';
import 'mcp_connection.dart';

/// The current provider tool-result contract is textual. Binary content is
/// reported explicitly so a completed side effect is never mistaken for a
/// missing tool invocation and retried just to obtain a different result type.
McpReply mcpResultText(sdk.CallToolResult result) {
  final List<String> parts = <String>[];
  final Set<String> unsupported = <String>{};
  for (final sdk.Content content in result.content) {
    switch (content) {
      case sdk.TextContent(:final String text):
        parts.add(text);
      case sdk.ResourceLink(:final String name, :final String uri):
        parts.add('$name: $uri');
      case sdk.EmbeddedResource(:final sdk.ResourceContents resource):
        if (resource is sdk.TextResourceContents) {
          parts.add('${resource.uri}\n${resource.text}');
        } else {
          unsupported.add('二进制资源');
        }
      case sdk.ImageContent():
        unsupported.add('图片');
      case sdk.AudioContent():
        unsupported.add('音频');
      default:
        unsupported.add(content.type);
    }
  }
  if (result.hasStructuredContent) {
    parts.add(jsonEncode(result.structuredContentJson!.toJson()));
  }
  if (unsupported.isNotEmpty) {
    parts.add(
      '服务器已返回结果，但当前聊天无法展示这些 MCP 内容：${unsupported.join('、')}。'
      '不要为获取内容自动重复执行有副作用的工具。',
    );
  }
  return McpReply(
    text: truncateForModel(
      parts.isEmpty
          ? (result.isError ? 'MCP 服务器报告工具执行失败，但未提供说明。' : 'MCP 工具已完成，服务器未返回内容。')
          : parts.join('\n\n'),
      hint: '不要为获取完整输出重复执行有副作用的 MCP 调用',
    ),
    isError: result.isError || unsupported.isNotEmpty,
  );
}
