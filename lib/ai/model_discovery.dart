/// 从 provider 拉模型清单、测单个模型可用性。
///
/// 两件事都是"设置页里点一下"的动作，不在聊天路径上，所以用一次性请求，
/// 不走 `http_transport.dart` 的流式重试——那边的重试是为流设计的，
/// 这里失败了用户自己再点一次更直观。
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/cancellation_token.dart';
import '../core/errors.dart';
import '../core/redact.dart';
import 'messages.dart';
import 'model_catalog.dart';
import 'provider_api.dart';
import 'provider_config.dart';
import 'provider_factory.dart';
import 'provider_headers.dart';

/// 探测超时。设置页里的动作要么很快成功要么快点报错，
/// 让用户对着转圈等 30 秒不如让他早点看到错误。
const Duration _kProbeTimeout = Duration(seconds: 20);

/// 拉取 [config] 的可用模型 id 列表。
///
/// 三家的 `/models` 都返回 `{data: [{id: ...}]}`（anthropic 也兼容这个形状），
/// 所以只有一份解析。返回的模型**只有 id**：没有一家的 `/models` 返回上下文
/// 窗口或能力标记，那些由用户在设置里填（默认值见 `kDefaultContextWindow`）。
///
/// 抛 [WepError]：没配 key、网络失败、端点不支持 `/models`。
/// 不返回空列表代替失败——空列表意味着"这个 provider 一个模型都没有"，
/// 和"我没问到"是两件事。
Future<List<String>> fetchModelIds(
  ProviderConfig config, {
  http.Client? client,
}) async {
  if (!config.isConfigured) {
    throw AuthError(
      '${config.displayName} 还没有配置 API Key',
      context: <String, Object?>{'providerId': config.id},
    );
  }

  final http.Client c = client ?? http.Client();
  try {
    final Uri url = Uri.parse('${_trimSlash(config.baseUrl)}/models');
    final http.Response response = await c
        .get(url, headers: _headersFor(config))
        .timeout(_kProbeTimeout);

    if (response.statusCode != 200) {
      throw ApiError(
        response.statusCode == 404
            // 404 在这里几乎总是"这个端点没有 /models"，而不是地址写错——
            // 说清楚才能让用户去手动添加而不是反复检查 base url。
            ? '这个端点不支持自动获取模型列表，请手动添加模型'
            : '获取模型列表失败',
        statusCode: response.statusCode,
        providerMessage: redact(_messageOf(response.body)),
      );
    }

    return _parseModelIds(utf8.decode(response.bodyBytes));
  } on WepError {
    rethrow;
  } on TimeoutException {
    throw NetworkError(
      '获取模型列表超时',
      context: <String, Object?>{'providerId': config.id},
    );
  } on Object catch (e) {
    throw NetworkError(
      '无法连接到 ${config.displayName}',
      context: <String, Object?>{'cause': redact(e.toString())},
    );
  } finally {
    if (client == null) c.close();
  }
}

List<String> _parseModelIds(String body) {
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    throw ApiError('模型列表不是合法 JSON', statusCode: 200);
  }

  if (decoded is! Map<String, Object?>) {
    throw ApiError('模型列表格式无法识别', statusCode: 200);
  }

  // OpenAI 风格是 {data: [...]}，少数端点直接给 {models: [...]}。
  final Object? list = decoded['data'] ?? decoded['models'];
  if (list is! List) {
    throw ApiError('模型列表里没有 data 字段', statusCode: 200);
  }

  final List<String> ids = <String>[];
  for (final Object? item in list) {
    // 有的端点给对象（{id: ...}），有的直接给字符串数组。
    if (item is String && item.isNotEmpty) {
      ids.add(item);
    } else if (item is Map<String, Object?>) {
      final Object? id = item['id'] ?? item['name'];
      if (id is String && id.isNotEmpty) ids.add(id);
    }
  }
  ids.sort();
  return ids;
}

/// 一次可用性探测的结果。
class ProbeResult {
  const ProbeResult._({required this.ok, required this.message, this.elapsed});

  factory ProbeResult.success(Duration elapsed, String reply) {
    return ProbeResult._(
      ok: true,
      // 把模型真的说了什么带上一小段：用户看到回复内容才真正确信这条通了，
      // 一个绿勾说明不了是不是打到了错误的模型。
      message: reply.isEmpty ? '连接正常' : _clip(reply, 40),
      elapsed: elapsed,
    );
  }

  factory ProbeResult.failure(String message) {
    return ProbeResult._(ok: false, message: message);
  }

  final bool ok;

  /// 成功时是模型的回复片段，失败时是错误说明。
  final String message;

  /// 成功时的往返耗时，给用户判断这个端点快不快。
  final Duration? elapsed;
}

/// 发一句 hi 测 [model] 是否真的可用。
///
/// 走完整的适配器链路（[createProviderApi] → `streamSimple`），不另写一条
/// 简化请求：探测的意义就是验证"聊天时走的那条路"通不通，用另一条路测等于
/// 没测。所以 base url、协议种类、兼容标记的错都能在这里暴露。
///
/// **不抛异常**：失败编码进 [ProbeResult]，和适配器同一条约定（§4-2）。
Future<ProbeResult> probeModel({
  required ModelSpec model,
  required ProviderConfig config,
  ProviderApi Function()? apiFactory,
}) async {
  final CancellationTokenSource source = CancellationTokenSource();
  // 超时靠取消而不是 Future.timeout：后者只是不再等结果，请求还在跑。
  final Timer timer = Timer(_kProbeTimeout, source.cancel);

  final Stopwatch sw = Stopwatch()..start();
  try {
    final ProviderApi api = apiFactory != null
        ? apiFactory()
        : createProviderApi(model: model, config: config);

    final ChatMessageModel reply = await api.streamSimple(
      ProviderRequest(
        model: model,
        messages: <ChatMessageModel>[ChatMessageModel.user('hi')],
        // 探测要便宜：够回一个词就行。不开思考——思考模型会先花几百个
        // token 想，既慢又贵，而我们只想知道连不连通。
        maxOutputTokens: 16,
      ),
      source.token,
    );
    sw.stop();

    if (reply.stopReason == StopReason.error) {
      return ProbeResult.failure(reply.errorMessage ?? '请求失败');
    }
    if (reply.stopReason == StopReason.aborted) {
      return ProbeResult.failure('探测超时（${_kProbeTimeout.inSeconds} 秒）');
    }
    return ProbeResult.success(sw.elapsed, reply.text.trim());
  } on WepError catch (e) {
    return ProbeResult.failure(e.message);
  } on Object catch (e) {
    return ProbeResult.failure(redact(e.toString()));
  } finally {
    timer.cancel();
    source.cancel();
  }
}

Map<String, String> _headersFor(ProviderConfig config) {
  // anthropic 用 x-api-key + 版本头，其余用 Bearer。这个差异在
  // 适配器里也有一份，但那边是流式 POST 的头，这里是 GET /models 的头，
  // 抽一个共享函数要把两处的差异都参数化，反而更绕。
  final Map<String, String> defaults = switch (config.apiKind) {
    ApiKind.anthropicMessages => <String, String>{
      'x-api-key': config.apiKey,
      'anthropic-version': '2023-06-01',
    },
    ApiKind.openaiCompletions || ApiKind.openaiResponses => <String, String>{
      'authorization': 'Bearer ${config.apiKey}',
    },
  };
  return buildProviderHeaders(defaults: defaults, custom: config.customHeaders);
}

String _messageOf(String body) {
  try {
    final Object? decoded = jsonDecode(body);
    if (decoded is Map<String, Object?>) {
      final Object? error = decoded['error'];
      if (error is Map<String, Object?>) {
        final Object? message = error['message'];
        if (message is String) return message;
      }
      if (error is String) return error;
    }
  } on FormatException {
    // 不是 JSON（网关的 HTML 错误页之类），用原文。
  }
  return _clip(body, 200);
}

String _clip(String text, int limit) {
  final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= limit ? flat : '${flat.substring(0, limit)}…';
}

String _trimSlash(String url) {
  String out = url;
  while (out.endsWith('/')) {
    out = out.substring(0, out.length - 1);
  }
  return out;
}
