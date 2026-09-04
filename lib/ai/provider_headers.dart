/// Provider 请求头的默认值、预设合并和边界校验。
library;

/// 这些头由 HTTP 传输层管理，不能由 provider 配置覆盖。
const Set<String> kForbiddenProviderHeaderNames = <String>{
  'host',
  'content-length',
  'connection',
  'transfer-encoding',
};

/// 将协议默认头和用户头合并。Header 名大小写不敏感，用户值覆盖默认值。
///
/// 传输层 Header 不进入结果：它们不是业务协议的一部分，交给 http 客户端
/// 自动生成更安全。其余 Header 允许覆盖认证头，供中转站使用非标准认证方式。
Map<String, String> buildProviderHeaders({
  required Map<String, String> defaults,
  Map<String, String> custom = const <String, String>{},
}) {
  final Map<String, String> result = <String, String>{...defaults};
  for (final MapEntry<String, String> entry in custom.entries) {
    final String name = entry.key.trim();
    final String value = entry.value.trim();
    if (name.isEmpty || value.isEmpty) continue;
    if (!isValidProviderHeaderName(name) ||
        !isValidProviderHeaderValue(value)) {
      continue;
    }
    final String lower = name.toLowerCase();
    if (kForbiddenProviderHeaderNames.contains(lower)) continue;
    result.removeWhere((String key, String _) => key.toLowerCase() == lower);
    result[name] = value;
  }
  return result;
}

/// 仅保留可序列化且可发送的 Header，供配置入口和旧配置迁移使用。
Map<String, String> normalizeProviderHeaders(Object? raw) {
  if (raw is! Map) return const <String, String>{};
  final Map<String, String> result = <String, String>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    if (entry.key is! String || entry.value is! String) continue;
    final String name = (entry.key as String).trim();
    final String value = (entry.value as String).trim();
    if (name.isEmpty || value.isEmpty) continue;
    if (!isValidProviderHeaderName(name) ||
        !isValidProviderHeaderValue(value)) {
      continue;
    }
    if (kForbiddenProviderHeaderNames.contains(name.toLowerCase())) continue;
    result[name] = value;
  }
  return result;
}

bool isValidProviderHeaderName(String value) {
  return value.codeUnits.every((int code) {
    if (code < 33 || code > 126) return false;
    return !':,()<>@[]\\"?={} \t'.codeUnits.contains(code);
  });
}

bool isValidProviderHeaderValue(String value) =>
    !value.contains(RegExp(r'[\r\n]'));

/// UI 里的快捷预设。预设只负责填充可编辑的实际 Header，不代表完整客户端协议。
Map<String, String> providerHeaderPreset(String? preset, String version) {
  final String v = version.trim().isEmpty
      ? providerHeaderPresetDefaultVersion(preset)
      : version.trim();
  return switch (preset) {
    'opencode' => <String, String>{
      'originator': 'opencode',
      'User-Agent': 'opencode/$v',
    },
    'codex' => <String, String>{
      'originator': 'codex_cli_rs',
      'User-Agent': 'codex_cli_rs/$v',
    },
    'claudeCode' => <String, String>{
      'User-Agent': 'claude-cli/$v (external, cli)',
      'x-app': 'cli',
    },
    _ => const <String, String>{},
  };
}

String providerHeaderPresetDefaultVersion(String? preset) {
  // 这是随应用发布的起始值，不是联网查询的“最新版”；用户可以覆盖。
  return switch (preset) {
    'opencode' => '1.18.27',
    'codex' => '0.153.2',
    'claudeCode' => '2.1.260',
    _ => '1.0.0',
  };
}
