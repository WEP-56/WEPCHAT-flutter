// ignore_for_file: curly_braces_in_flow_control_structures
library;

import 'dart:convert';
import '../../ai/provider_api.dart';
import '../tool.dart';
import 'web_client.dart';

class WebFetchTool extends Tool {
  const WebFetchTool();
  @override
  String get permissionId => 'web_fetch';
  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'web_fetch',
    description:
        '专一读取一个已知网页来源。target 可是 web_search 返回的 source_id/URL；只执行 GET，提取正文，不接受自定义 Header、Cookie 或 Authorization，也不会递归发现链接。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'target': <String, Object?>{
          'type': 'string',
          'description': 'source_id 或完整 https URL',
        },
      },
      'required': <String>['target'],
    },
  );
  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final Object? raw = arguments['target'];
    if (raw is! String || raw.trim().isEmpty)
      return ToolResult.error('参数 target 必须是非空字符串');
    final Uri? uri = Uri.tryParse(raw.trim());
    if (uri == null || uri.scheme != 'https' || uri.host.isEmpty)
      return ToolResult.error('target 必须是完整的 https URL');
    try {
      final WebResponse response = await webRequest(
        method: 'GET',
        url: uri,
        headers: const <String, String>{
          'accept': 'text/html,application/pdf,text/plain;q=0.9,*/*;q=0.1',
        },
        token: context.token,
      );
      final String contentType = response.headers['content-type'] ?? '';
      if (contentType.contains('pdf')) {
        return ToolResult.error('当前版本暂不支持 PDF 正文提取，请提供 HTML 或纯文本来源');
      }
      final String text = _extract(response.text, contentType);
      if (text.trim().isEmpty) return ToolResult.error('网页没有可提取的正文');
      final String capped = text.length > 120000
          ? '${text.substring(0, 120000)}…'
          : text;
      return ToolResult.ok(
        jsonEncode(<String, Object?>{
          'url': uri.toString(),
          'title': _title(response.text),
          'content_type': contentType,
          'content': capped,
        }),
        uiPayload: <String, Object?>{
          'url': uri.toString(),
          'contentType': contentType,
        },
      );
    } on FormatException {
      return ToolResult.error('网页内容无法按 UTF-8 解析');
    }
  }
}

String _extract(String raw, String contentType) {
  if (contentType.contains('html')) {
    return raw
        .replaceAll(
          RegExp(r'<script[\\s\\S]*?</script>', caseSensitive: false),
          '',
        )
        .replaceAll(
          RegExp(r'<style[\\s\\S]*?</style>', caseSensitive: false),
          '',
        )
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'\\s+'), ' ')
        .trim();
  }
  return raw.trim();
}

String _title(String raw) {
  final Match? m = RegExp(
    r'<title[^>]*>([\\s\\S]*?)</title>',
    caseSensitive: false,
  ).firstMatch(raw);
  return m?.group(1)?.replaceAll(RegExp(r'\\s+'), ' ').trim() ?? '';
}
