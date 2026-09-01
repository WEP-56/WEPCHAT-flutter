/// 按模型的兼容标记（实施 TODO §4.2）。
///
/// 这是从 pi 抄来的最值得抄的一个决定：差异用"按模型的兼容标记"表达，
/// **不用"按厂商的 if 分支"**。因为同一个 `/v1/chat/completions` 端点后面
/// 是 DeepSeek、Kimi、GLM、Qwen、本地 vLLM，它们的差异不在厂商而在模型。
///
/// pi 有近 30 个标记，第一版只要九个。新增一个标记必须同时说明"哪个真实
/// 模型需要它"——不为假想的模型加标记（§4-6、AGENTS.md §3）。
library;

/// 思考内容的传递方式。各家完全不同，没有共同子集。
enum ThinkingFormat {
  /// 模型不支持思考。
  none,

  /// OpenAI o 系列：请求带 `reasoning_effort: low|medium|high`，
  /// 响应里思考内容不返回（只计入 `reasoning_tokens`）。
  openaiReasoningEffort,

  /// Anthropic：请求带 `thinking: {type: enabled, budget_tokens: N}`，
  /// 响应是 `thinking` 块且带 signature，回传必须原样（§4-9）。
  anthropicThinking,

  /// DeepSeek R1：响应的 delta 里多一个 `reasoning_content` 字段，
  /// 请求侧不需要开关。
  deepseekReasoningContent,

  /// Qwen3：请求带 `enable_thinking: true`，响应同 deepseek 的字段。
  qwenEnableThinking,
}

/// prompt cache 的开启方式。
enum CacheControlFormat {
  /// 不支持，或服务端自动缓存不需要参数（DeepSeek / Kimi 属于这类）。
  none,

  /// Anthropic 风格：在 block 上挂 `cache_control: {type: ephemeral}`，
  /// 最多四个落点（§6-9）。
  anthropic,
}

/// 一个模型的兼容标记集合。
class ModelCompat {
  const ModelCompat({
    this.maxTokensField = 'max_tokens',
    this.supportsDeveloperRole = false,
    this.thinking = ThinkingFormat.none,
    this.cache = CacheControlFormat.none,
    this.supportsPromptCacheKey = false,
    this.requiresToolResultName = false,
    this.supportsParallelToolCalls = true,
    this.visionInput = false,
    this.supportsTemperature = true,
  });

  /// `max_tokens` 还是 `max_completion_tokens`。
  ///
  /// 需要它的真实模型：OpenAI o1/o3/o4 系列和 gpt-5 只认后者，
  /// 传前者直接 400。
  final String maxTokensField;

  /// system prompt 用 `developer` 角色还是 `system`。
  ///
  /// 需要它的真实模型：OpenAI o 系列推荐 `developer`，旧模型只认 `system`。
  final bool supportsDeveloperRole;

  final ThinkingFormat thinking;
  final CacheControlFormat cache;

  /// 是否接受 `prompt_cache_key`。
  ///
  /// 需要它的真实模型：OpenAI 官方端点。填会话 id 把同一会话路由到同一台
  /// 缓存副本（§6-10）。兼容端点大多不认这个字段，传了会被忽略或报错。
  final bool supportsPromptCacheKey;

  /// tool result 是否必须带 `name`。
  ///
  /// 需要它的真实模型：部分自建 vLLM / Ollama 的 OpenAI 兼容层。
  /// 官方端点不需要，多传无害但会改变请求字节（影响缓存），所以要能关。
  final bool requiresToolResultName;

  /// 是否支持一轮返回多个 tool_call。
  ///
  /// 需要它的真实模型：部分兼容端点一轮只回一个，传
  /// `parallel_tool_calls: true` 会 400。
  final bool supportsParallelToolCalls;

  final bool visionInput;

  /// 是否接受 `temperature`。
  ///
  /// 需要它的真实模型：OpenAI o 系列拒绝 temperature（必须省略，
  /// 传 1.0 也不行）。
  final bool supportsTemperature;

  ModelCompat copyWith({
    String? maxTokensField,
    bool? supportsDeveloperRole,
    ThinkingFormat? thinking,
    CacheControlFormat? cache,
    bool? supportsPromptCacheKey,
    bool? requiresToolResultName,
    bool? supportsParallelToolCalls,
    bool? visionInput,
    bool? supportsTemperature,
  }) {
    return ModelCompat(
      maxTokensField: maxTokensField ?? this.maxTokensField,
      supportsDeveloperRole:
          supportsDeveloperRole ?? this.supportsDeveloperRole,
      thinking: thinking ?? this.thinking,
      cache: cache ?? this.cache,
      supportsPromptCacheKey:
          supportsPromptCacheKey ?? this.supportsPromptCacheKey,
      requiresToolResultName:
          requiresToolResultName ?? this.requiresToolResultName,
      supportsParallelToolCalls:
          supportsParallelToolCalls ?? this.supportsParallelToolCalls,
      visionInput: visionInput ?? this.visionInput,
      supportsTemperature: supportsTemperature ?? this.supportsTemperature,
    );
  }
}
