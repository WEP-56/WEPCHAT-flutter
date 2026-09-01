/// 模型目录（实施 TODO §4-5）。
///
/// 兼容标记存在这里，**不硬编码在适配器里**——用户在设置里添加自定义模型时
/// 要能选这些开关（协议 §8）。适配器只读 [ModelSpec.compat]，不认识具体
/// 模型名。
library;

import 'model_compat.dart';

/// API 协议种类。协议要求支持三种（§4）。
enum ApiKind {
  /// `POST /v1/chat/completions`，SSE 里是 choices/delta 结构。
  /// 后面可能是 OpenAI、DeepSeek、Kimi、GLM、Qwen、vLLM……
  openaiCompletions,

  /// `POST /v1/responses`，事件是带 type 的具名 JSON。
  openaiResponses,

  /// `POST /v1/messages`，content_block 三段式。
  anthropicMessages,
}

/// 一个可用模型的完整描述。
class ModelSpec {
  const ModelSpec({
    required this.id,
    required this.displayName,
    required this.providerId,
    required this.apiKind,
    required this.contextWindow,
    required this.maxOutputTokens,
    this.compat = const ModelCompat(),
  });

  /// 请求体里的模型标识，原样发给服务端。
  final String id;

  /// 界面显示名。
  final String displayName;

  /// 所属 provider（决定 base url 与 api key 从哪取）。
  final String providerId;

  final ApiKind apiKind;

  /// 上下文窗口大小，压缩阈值要用（§6-16）。
  final int contextWindow;

  final int maxOutputTokens;

  final ModelCompat compat;
}

/// 内置模型目录。
///
/// 只列真实存在、参数已确认的模型。**不为假想模型占位**（AGENTS.md §3）——
/// 一个错的 contextWindow 会让压缩在错误的时机触发，比没有这个模型更糟。
///
/// 用户自定义模型走设置界面，运行时合并进这份清单。
const List<ModelSpec> kBuiltinModels = <ModelSpec>[
  // ---- Anthropic ----
  ModelSpec(
    id: 'claude-sonnet-4-5',
    displayName: 'Claude Sonnet 4.5',
    providerId: 'anthropic',
    apiKind: ApiKind.anthropicMessages,
    contextWindow: 200000,
    maxOutputTokens: 64000,
    compat: ModelCompat(
      thinking: ThinkingFormat.anthropicThinking,
      cache: CacheControlFormat.anthropic,
      visionInput: true,
    ),
  ),
  ModelSpec(
    id: 'claude-opus-4-5',
    displayName: 'Claude Opus 4.5',
    providerId: 'anthropic',
    apiKind: ApiKind.anthropicMessages,
    contextWindow: 200000,
    maxOutputTokens: 64000,
    compat: ModelCompat(
      thinking: ThinkingFormat.anthropicThinking,
      cache: CacheControlFormat.anthropic,
      visionInput: true,
    ),
  ),
  ModelSpec(
    id: 'claude-haiku-4-5',
    displayName: 'Claude Haiku 4.5',
    providerId: 'anthropic',
    apiKind: ApiKind.anthropicMessages,
    contextWindow: 200000,
    maxOutputTokens: 32000,
    compat: ModelCompat(
      cache: CacheControlFormat.anthropic,
      visionInput: true,
    ),
  ),

  // ---- OpenAI ----
  // maxTokensField：o 系列与 gpt-5 只认 max_completion_tokens。
  // supportsTemperature: false：o 系列拒绝 temperature，省略才行。
  ModelSpec(
    id: 'gpt-5',
    displayName: 'GPT-5',
    providerId: 'openai',
    apiKind: ApiKind.openaiCompletions,
    contextWindow: 400000,
    maxOutputTokens: 128000,
    compat: ModelCompat(
      maxTokensField: 'max_completion_tokens',
      supportsDeveloperRole: true,
      thinking: ThinkingFormat.openaiReasoningEffort,
      supportsPromptCacheKey: true,
      visionInput: true,
      supportsTemperature: false,
    ),
  ),
  ModelSpec(
    id: 'gpt-4.1',
    displayName: 'GPT-4.1',
    providerId: 'openai',
    apiKind: ApiKind.openaiCompletions,
    contextWindow: 1047576,
    maxOutputTokens: 32768,
    compat: ModelCompat(
      supportsPromptCacheKey: true,
      visionInput: true,
    ),
  ),

  // ---- DeepSeek ----
  // 走 openai-completions 端点，但思考内容在 reasoning_content 字段里，
  // 且服务端自动缓存不需要参数——正是"差异在模型不在厂商"的例子。
  ModelSpec(
    id: 'deepseek-reasoner',
    displayName: 'DeepSeek V3.2',
    providerId: 'deepseek',
    apiKind: ApiKind.openaiCompletions,
    contextWindow: 128000,
    maxOutputTokens: 65536,
    compat: ModelCompat(
      thinking: ThinkingFormat.deepseekReasoningContent,
    ),
  ),

  // ---- 阿里 ----
  ModelSpec(
    id: 'qwen3-max',
    displayName: 'Qwen3 Max',
    providerId: 'alibaba',
    apiKind: ApiKind.openaiCompletions,
    contextWindow: 262144,
    maxOutputTokens: 65536,
    compat: ModelCompat(
      thinking: ThinkingFormat.qwenEnableThinking,
      visionInput: true,
    ),
  ),

  // ---- Google ----
  // Gemini 的 OpenAI 兼容端点。原生 API 不在协议要求的三种里，
  // 所以走兼容层——代价是拿不到 thinking 内容。
  ModelSpec(
    id: 'gemini-2.5-pro',
    displayName: 'Gemini 2.5 Pro',
    providerId: 'google',
    apiKind: ApiKind.openaiCompletions,
    contextWindow: 1048576,
    maxOutputTokens: 65536,
    compat: ModelCompat(visionInput: true),
  ),
];

/// 按展示名查模型。
///
/// M0 的 `SessionStore` 把展示名存进了 `model_id` 列，这个查询是接上
/// 真模型的桥。M1 收尾时改成存 [ModelSpec.id]，这个方法保留给
/// 旧数据迁移用。
ModelSpec? findModelByDisplayName(String displayName) {
  for (final ModelSpec spec in kBuiltinModels) {
    if (spec.displayName == displayName) return spec;
  }
  return null;
}

ModelSpec? findModelById(String id) {
  for (final ModelSpec spec in kBuiltinModels) {
    if (spec.id == id) return spec;
  }
  return null;
}
