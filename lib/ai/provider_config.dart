/// provider 配置（实施 TODO §10-4、§13.4）。
///
/// 用户视角只有四个字段：**名称、API 类别、baseUrl、Key**。一个 provider 是
/// "一个端点 + 一把钥匙 + 一种协议"，不是"一个厂商"——中转站、本地 vLLM、
/// 官方端点在这里是同一种东西。
///
/// [ApiKind] 在这里而不在模型上：协议由端点决定，同一个端点后面的所有模型
/// 都走同一套请求格式。
library;

import '../core/ulid.dart';

/// API 协议种类。协议要求支持三种（§4）。
enum ApiKind {
  /// `POST /v1/chat/completions`，SSE 里是 choices/delta 结构。
  /// 绝大多数端点都是这种：OpenAI、DeepSeek、Kimi、GLM、Qwen、vLLM、中转站。
  openaiCompletions('OpenAI 兼容', 'chat/completions，兼容性最好，先试这个'),

  /// `POST /v1/messages`，content_block 三段式。
  anthropicMessages('Anthropic', 'Claude 官方端点'),

  /// `POST /v1/responses`，事件是带 type 的具名 JSON。
  openaiResponses('OpenAI Responses', 'OpenAI 新端点，不确定就选“OpenAI 兼容”');

  const ApiKind(this.label, this.hint);

  /// 界面显示名。
  final String label;

  /// 选择时的一句说明。用户不该需要读文档才能选对这一项。
  final String hint;

  static ApiKind? byName(Object? raw) {
    if (raw is! String) return null;
    for (final ApiKind kind in ApiKind.values) {
      if (kind.name == raw) return kind;
    }
    return null;
  }
}

/// 一个 provider 的配置。
class ProviderConfig {
  const ProviderConfig({
    required this.id,
    required this.displayName,
    required this.apiKind,
    required this.baseUrl,
    this.apiKey = '',
    this.builtin = false,
  });

  /// 新建一个用户自定义 provider。id 用 ULID，避免和内置的撞名。
  factory ProviderConfig.create({
    required String displayName,
    required ApiKind apiKind,
    required String baseUrl,
    String apiKey = '',
  }) {
    return ProviderConfig(
      id: Ulid.generate(),
      displayName: displayName,
      apiKind: apiKind,
      baseUrl: baseUrl,
      apiKey: apiKey,
    );
  }

  /// 稳定 id，[ModelSpec.providerId] 指向它。
  final String id;

  final String displayName;

  final ApiKind apiKind;

  /// 端点根地址，不含 `/chat/completions` 这类路径后缀。
  final String baseUrl;

  /// 明文 key，存在 App 私有目录的 settings.json 里（§13.4 的决定）。
  ///
  /// **界面永不显示明文**，只显示 [maskedKey]；日志走 `redact()`。
  final String apiKey;

  /// 内置 provider（首启种子）。
  ///
  /// 只影响一件事：不允许删除，删了下次启动还会回来，不如不让删。
  /// 名称、地址、Key、API 类别都可以改。
  final bool builtin;

  bool get isConfigured => apiKey.isNotEmpty;

  /// 掩码形式，给界面看。
  ///
  /// 保留头 6 尾 4：头部能认出是哪家的 key（`sk-ant-` / `sk-proj-`），
  /// 尾部够用户和控制台里的记录比对。
  String get maskedKey {
    if (apiKey.isEmpty) return '未配置';
    if (apiKey.length <= 12) return '••••••••';
    return '${apiKey.substring(0, 6)}••••••••'
        '${apiKey.substring(apiKey.length - 4)}';
  }

  ProviderConfig copyWith({
    String? displayName,
    ApiKind? apiKind,
    String? baseUrl,
    String? apiKey,
  }) {
    return ProviderConfig(
      id: id,
      displayName: displayName ?? this.displayName,
      apiKind: apiKind ?? this.apiKind,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      builtin: builtin,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'displayName': displayName,
        'apiKind': apiKind.name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'builtin': builtin,
      };

  /// 从 JSON 读。id / baseUrl / apiKind 任一缺失就返回 null——
  /// 这三个少一个都发不出请求，补默认值只会让错误推迟到用户点发送。
  static ProviderConfig? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Object? id = raw['id'];
    final Object? baseUrl = raw['baseUrl'];
    final ApiKind? kind = ApiKind.byName(raw['apiKind']);
    if (id is! String || id.isEmpty) return null;
    if (baseUrl is! String || baseUrl.isEmpty) return null;
    if (kind == null) return null;

    return ProviderConfig(
      id: id,
      displayName: raw['displayName'] as String? ?? id,
      apiKind: kind,
      baseUrl: baseUrl,
      apiKey: raw['apiKey'] as String? ?? '',
      builtin: raw['builtin'] as bool? ?? false,
    );
  }
}

/// 首次启动的种子 provider。
///
/// key 一律为空——用户自己填。这份清单只是省掉手抄 base url，
/// 不代表这些 provider 可用（`isConfigured` 才代表）。
const List<ProviderConfig> kSeedProviders = <ProviderConfig>[
  ProviderConfig(
    id: 'anthropic',
    displayName: 'Anthropic',
    apiKind: ApiKind.anthropicMessages,
    baseUrl: 'https://api.anthropic.com',
    builtin: true,
  ),
  ProviderConfig(
    id: 'openai',
    displayName: 'OpenAI',
    apiKind: ApiKind.openaiCompletions,
    baseUrl: 'https://api.openai.com/v1',
    builtin: true,
  ),
  ProviderConfig(
    id: 'deepseek',
    displayName: 'DeepSeek',
    apiKind: ApiKind.openaiCompletions,
    baseUrl: 'https://api.deepseek.com/v1',
    builtin: true,
  ),
  ProviderConfig(
    id: 'alibaba',
    displayName: '阿里云百炼',
    apiKind: ApiKind.openaiCompletions,
    baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    builtin: true,
  ),
  ProviderConfig(
    id: 'google',
    displayName: 'Google',
    apiKind: ApiKind.openaiCompletions,
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    builtin: true,
  ),
];
