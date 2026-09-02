// ignore_for_file: curly_braces_in_flow_control_structures
library;

import 'dart:convert';
import '../../ai/provider_api.dart';
import '../../state/app_settings.dart';
import '../../models/settings.dart';
import '../tool.dart';
import 'web_client.dart';

class WebSearchTool extends Tool {
  const WebSearchTool();
  @override
  String get permissionId => 'web_search';
  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'web_search',
    description:
        '广泛发现候选网页来源。返回多个标题、URL、摘要和来源标识；不要把摘要当完整事实，需要深入阅读时再调用 web_fetch。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'query': <String, Object?>{
          'type': 'string',
          'description': '要搜索的问题或主题',
        },
        'freshness': <String, Object?>{
          'type': 'string',
          'enum': <String>['none', 'day', 'week', 'month', 'year'],
        },
        'domains': <String, Object?>{
          'type': 'array',
          'items': <String, Object?>{'type': 'string'},
        },
        'max_results': <String, Object?>{
          'type': 'integer',
          'description': '1 到 8，默认 5',
        },
      },
      'required': <String>['query'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final AppSettings? settings = context.settings;
    if (settings == null || settings.searchApiKey.trim().isEmpty)
      return ToolResult.error('尚未配置搜索 API Key，请在设置页配置 Tavily Key。');
    final SearchProviderConfig? provider = settings.searchProvider;
    if (provider == null || provider.baseUrl.trim().isEmpty) {
      return ToolResult.error('尚未配置搜索服务地址，请在设置页配置搜索提供商。');
    }
    if (provider.kind != 'searxng' && provider.apiKey.trim().isEmpty) {
      return ToolResult.error('当前搜索提供商尚未配置 API Key，请在设置页填写。');
    }
    final Object? rawQuery = arguments['query'];
    if (rawQuery is! String || rawQuery.trim().isEmpty)
      return ToolResult.error('参数 query 必须是非空字符串');
    final int max = _positive(arguments['max_results'], 5).clamp(1, 8);
    final List<String> domains = _domains(arguments['domains']);
    final String? freshness = arguments['freshness'] is String
        ? arguments['freshness'] as String
        : null;
    try {
      final String query = rawQuery.trim();
      final WebResponse response;
      if (provider.kind == 'searxng') {
        final Uri uri = Uri.parse('${_trim(provider.baseUrl)}/search').replace(
          queryParameters: <String, String>{'q': query, 'format': 'json'},
        );
        response = await webRequest(
          method: 'GET',
          url: uri,
          token: context.token,
        );
      } else {
        final Map<String, Object?> body = _requestBody(
          provider,
          query,
          max,
          domains,
          freshness,
        );
        response = await webRequest(
          method: 'POST',
          url: Uri.parse(
            '${_trim(provider.baseUrl)}${provider.kind == 'serper' ? '/search' : '/search'}',
          ),
          headers: <String, String>{
            'content-type': 'application/json',
            if (provider.kind == 'serper') 'X-API-KEY': provider.apiKey,
            if (provider.kind == 'exa') 'x-api-key': provider.apiKey,
          },
          body: utf8.encode(jsonEncode(body)),
          token: context.token,
        );
      }
      final Object? decoded = jsonDecode(response.text);
      if (decoded is! Map<String, Object?>)
        return ToolResult.error('搜索服务返回了无法识别的结果');
      final List<Object?> results = _resultsOf(provider.kind, decoded);
      final List<Map<String, Object?>> normalized = <Map<String, Object?>>[];
      for (int i = 0; i < results.length && i < max; i++) {
        final Object? item = results[i];
        if (item is! Map<String, Object?> || item['url'] is! String) continue;
        normalized.add(<String, Object?>{
          'source_id': item['url'],
          'title': item['title'] as String? ?? item['url'],
          'url': item['url'],
          'snippet':
              '${item['content'] ?? item['snippet'] ?? item['text'] ?? item['description'] ?? ''}',
          'published_at': item['published_date'],
          'source': Uri.tryParse(item['url'] as String)?.host ?? '',
        });
      }
      return ToolResult.ok(
        jsonEncode(<String, Object?>{
          'query': rawQuery.trim(),
          'results': normalized,
        }),
        uiPayload: <String, Object?>{'results': normalized},
      );
    } on FormatException {
      return ToolResult.error('搜索服务返回了无效 JSON');
    }
  }
}

Map<String, Object?> _requestBody(
  SearchProviderConfig provider,
  String query,
  int max,
  List<String> domains,
  String? freshness,
) {
  if (provider.kind == 'exa') {
    return <String, Object?>{
      'query': query,
      'numResults': max,
      if (domains.isNotEmpty) 'includeDomains': domains,
      'contents': <String, Object?>{
        'highlights': <String, Object?>{'maxCharacters': 1000},
      },
    };
  }
  if (provider.kind == 'serper')
    return <String, Object?>{'q': query, 'num': max};
  return <String, Object?>{
    'api_key': provider.apiKey,
    'query': query,
    'search_depth': 'basic',
    'max_results': max,
    'include_answer': false,
    if (domains.isNotEmpty) 'include_domains': domains,
    if (freshness != null && freshness != 'none') 'days': _days(freshness),
  };
}

List<Object?> _resultsOf(String kind, Map<String, Object?> decoded) {
  final Object? value = decoded['results'] ?? decoded['organic'];
  return value is List ? value : const <Object?>[];
}

int _positive(Object? raw, int fallback) =>
    raw is int && raw > 0 ? raw : int.tryParse('$raw') ?? fallback;
List<String> _domains(Object? raw) => raw is List
    ? raw
          .whereType<String>()
          .map((String s) => s.trim())
          .where((String s) => s.isNotEmpty)
          .take(10)
          .toList()
    : <String>[];
int _days(String freshness) => switch (freshness) {
  'day' => 1,
  'week' => 7,
  'month' => 30,
  'year' => 365,
  _ => 0,
};
String _trim(String value) =>
    value.endsWith('/') ? value.substring(0, value.length - 1) : value;
