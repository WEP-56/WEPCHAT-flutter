part of 'app_settings.dart';

List<ProviderConfig> _readProviders(Object? raw) {
  if (raw is! List) return List<ProviderConfig>.of(kSeedProviders);
  final List<ProviderConfig> out = <ProviderConfig>[];
  for (final Object? item in raw) {
    final ProviderConfig? parsed = ProviderConfig.fromJson(item);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

List<SearchProviderConfig> _readSearchProviders(
  Object? raw, {
  String? legacyId,
  String? legacyKey,
  String? legacyBaseUrl,
}) {
  if (raw is List) {
    final List<SearchProviderConfig> out = <SearchProviderConfig>[];
    for (final Object? item in raw) {
      final SearchProviderConfig? parsed = SearchProviderConfig.fromJson(item);
      if (parsed != null) out.add(parsed);
    }
    if (out.isNotEmpty) return out;
  }
  return <SearchProviderConfig>[
    for (final SearchProviderConfig preset in kSearchProviderPresets)
      preset.id == (legacyId ?? 'tavily')
          ? preset.copyWith(
              apiKey: legacyKey ?? '',
              baseUrl: legacyBaseUrl == null || legacyBaseUrl.isEmpty
                  ? preset.baseUrl
                  : legacyBaseUrl,
            )
          : preset,
  ];
}

List<ModelSpec> _readModels(Object? raw) {
  if (raw is! List) return List<ModelSpec>.of(kSeedModels);
  final List<ModelSpec> out = <ModelSpec>[];
  for (final Object? item in raw) {
    final ModelSpec? parsed = ModelSpec.fromJson(item);
    if (parsed != null) out.add(parsed);
  }
  return out;
}

Map<String, ToolPermission> _readPermissions(Object? raw) {
  final Map<String, ToolPermission> out = <String, ToolPermission>{
    for (final ToolPermissionSpec spec in kToolPermissionSpecs)
      spec.id: spec.defaultPermission,
  };
  if (raw is! Map<String, Object?>) return out;
  for (final MapEntry<String, Object?> entry in raw.entries) {
    if (!out.containsKey(entry.key)) continue;
    final ToolPermission? value = _enumByName(
      entry.value,
      ToolPermission.values,
      (ToolPermission v) => v.name,
    );
    if (value != null) out[entry.key] = value;
  }
  return out;
}

T _readEnum<T>(
  Object? raw,
  List<T> values,
  T fallback,
  String Function(T) nameOf,
) {
  return _enumByName(raw, values, nameOf) ?? fallback;
}

T? _enumByName<T>(Object? raw, List<T> values, String Function(T) nameOf) {
  if (raw is! String) return null;
  for (final T value in values) {
    if (nameOf(value) == raw) return value;
  }
  return null;
}
