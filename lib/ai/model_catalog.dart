/// 模型描述（实施 TODO §4-5）。
///
/// 模型是**用户数据**，不是内置常量：用户填一个 provider，从 `/models` 拉一
/// 份清单或手输几个名字，就得到自己的模型列表。`kSeedModels` 只是首次启动
/// 的种子，之后磁盘上的清单是权威。
///
/// [ApiKind] 不在这里——它是 provider 的属性（一个端点一种协议），
/// 见 `provider_config.dart`。
library;

import 'model_compat.dart';

/// 一个可用模型。
class ModelSpec {
  /// 窗口与输出上限给了默认值：从 `/models` 拉回来的只有一个 id，服务端
  /// 不告诉我们窗口多大。默认值够日常聊天用，用户想改就在模型详情里改。
  const ModelSpec({
    required this.id,
    required this.providerId,
    this.contextWindow = kDefaultContextWindow,
    this.maxOutputTokens = kDefaultMaxOutputTokens,
    String? displayName,
    this.compat = const ModelCompat(),
  }) : _displayName = displayName;

  /// 请求体里的模型标识，原样发给服务端。
  final String id;

  /// 所属 provider（决定 base url、api key、API 协议）。
  final String providerId;

  final String? _displayName;

  /// 界面显示名。没单独设就用 [id]——从 `/models` 拉回来的只有 id，
  /// 让用户为每个模型再起一个名字是没必要的负担。
  String get displayName {
    final String? name = _displayName;
    return name == null || name.isEmpty ? id : name;
  }

  /// 上下文窗口大小，压缩阈值要用（§6-16）。
  final int contextWindow;

  final int maxOutputTokens;

  final ModelCompat compat;

  /// 全局唯一键。
  ///
  /// 两个 provider 挂同一个模型 id 是常见的（官方端点 + 中转站），所以
  /// 单靠 [id] 不够。会话的 `model_id` 列存这个值。
  String get key => '$providerId/$id';

  ModelSpec copyWith({
    String? displayName,
    int? contextWindow,
    int? maxOutputTokens,
    ModelCompat? compat,
  }) {
    return ModelSpec(
      id: id,
      providerId: providerId,
      displayName: displayName ?? _displayName,
      contextWindow: contextWindow ?? this.contextWindow,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      compat: compat ?? this.compat,
    );
  }

  Map<String, Object?> toJson() {
    final Map<String, Object?> out = <String, Object?>{
      'id': id,
      'providerId': providerId,
      'contextWindow': contextWindow,
      'maxOutputTokens': maxOutputTokens,
    };
    final String? name = _displayName;
    if (name != null && name.isNotEmpty) out['displayName'] = name;
    final Map<String, Object?> compatJson = compat.toJson();
    if (compatJson.isNotEmpty) out['compat'] = compatJson;
    return out;
  }

  /// 从 JSON 读。id 或 providerId 缺失时返回 null——
  /// 一个没有归属的模型没法发请求，伪造一个默认 provider 只会让错误
  /// 推迟到用户点发送的那一刻。
  static ModelSpec? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Object? id = raw['id'];
    final Object? providerId = raw['providerId'];
    if (id is! String || id.isEmpty) return null;
    if (providerId is! String || providerId.isEmpty) return null;

    return ModelSpec(
      id: id,
      providerId: providerId,
      displayName: raw['displayName'] as String?,
      contextWindow:
          (raw['contextWindow'] as num?)?.toInt() ?? kDefaultContextWindow,
      maxOutputTokens:
          (raw['maxOutputTokens'] as num?)?.toInt() ?? kDefaultMaxOutputTokens,
      compat: ModelCompat.fromJson(raw['compat']),
    );
  }
}

/// 手动添加或从 `/models` 拉取时的窗口默认值。
///
/// `/models` 端点**不返回**上下文窗口（三家都不返回），所以只能给个保守
/// 默认让用户自己改。取 128K 是因为它对现在的主流模型都不算离谱；
/// 猜大了会让压缩在该触发时不触发，那比猜小更糟。
const int kDefaultContextWindow = 128000;
const int kDefaultMaxOutputTokens = 8192;

/// 首次启动的种子模型。
///
/// 只是省掉用户手输几个常用名字，**不是权威清单**——用户删掉它们、改掉它们
/// 的元数据都可以，磁盘上的值优先。所以这里的参数准不准不影响正确性，
/// 用户随时能在设置里改。
const List<ModelSpec> kSeedModels = <ModelSpec>[
  // ---- Anthropic ----
  ModelSpec(
    id: 'claude-sonnet-4-5',
    displayName: 'Claude Sonnet 4.5',
    providerId: 'anthropic',
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
    contextWindow: 1047576,
    maxOutputTokens: 32768,
    compat: ModelCompat(
      supportsPromptCacheKey: true,
      visionInput: true,
    ),
  ),

  // ---- DeepSeek ----
  // 思考内容在 reasoning_content 字段里，服务端自动缓存不需要参数
  // ——正是"差异在模型不在厂商"的例子。
  ModelSpec(
    id: 'deepseek-reasoner',
    displayName: 'DeepSeek V3.2',
    providerId: 'deepseek',
    contextWindow: 128000,
    maxOutputTokens: 65536,
    compat: ModelCompat(thinking: ThinkingFormat.deepseekReasoningContent),
  ),
  ModelSpec(
    id: 'deepseek-chat',
    displayName: 'DeepSeek Chat',
    providerId: 'deepseek',
    contextWindow: 128000,
    maxOutputTokens: 8192,
  ),

  // ---- 阿里 ----
  ModelSpec(
    id: 'qwen3-max',
    displayName: 'Qwen3 Max',
    providerId: 'alibaba',
    contextWindow: 262144,
    maxOutputTokens: 65536,
    compat: ModelCompat(
      thinking: ThinkingFormat.qwenEnableThinking,
      visionInput: true,
    ),
  ),

  // ---- Google ----
  // 走 OpenAI 兼容端点。代价是拿不到 thinking 内容。
  ModelSpec(
    id: 'gemini-2.5-pro',
    displayName: 'Gemini 2.5 Pro',
    providerId: 'google',
    contextWindow: 1048576,
    maxOutputTokens: 65536,
    compat: ModelCompat(visionInput: true),
  ),
];
