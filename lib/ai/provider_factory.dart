/// 按 provider 的 [ApiKind] 建适配器（实施 TODO §4.1）。
///
/// 这是唯一一处知道"三个适配器类都存在"的地方。上层（agent、SessionStore）
/// 只见 [ProviderApi]，加第四种协议时只改这个文件加一个 enum 分支。
library;

import '../core/errors.dart';
import 'anthropic/anthropic_api.dart';
import 'model_catalog.dart';
import 'openai/openai_completions_api.dart';
import 'openai/openai_responses_api.dart';
import 'provider_api.dart';
import 'provider_config.dart';

/// 为 [model] 建一个适配器。
///
/// [model] 只用来校验归属；协议种类取自 [config]——端点决定协议。
///
/// 抛 [AuthError]：[config] 没配 key。这个失败要在发请求之前暴露，而不是
/// 让空 key 出去换回一个 401——后者的措辞来自服务端，各家不同，用户看不出
/// 是"我没填 key"。
ProviderApi createProviderApi({
  required ModelSpec model,
  required ProviderConfig config,
}) {
  if (model.providerId != config.id) {
    throw StateError('模型 ${model.id} 属于 ${model.providerId}，不是 ${config.id}');
  }
  if (!config.isConfigured) {
    throw AuthError(
      '${config.displayName} 还没有配置 API Key',
      context: <String, Object?>{'providerId': config.id},
    );
  }

  return switch (config.apiKind) {
    ApiKind.anthropicMessages => AnthropicApi(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
    ),
    ApiKind.openaiCompletions => OpenAiCompletionsApi(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
    ),
    ApiKind.openaiResponses => OpenAiResponsesApi(
      apiKey: config.apiKey,
      baseUrl: config.baseUrl,
    ),
  };
}
