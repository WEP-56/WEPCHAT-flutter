import '../ai/provider_api.dart';

/// Validates the small JSON Schema subset accepted by tool declarations.
class ToolSchemaValidator {
  const ToolSchemaValidator();

  String? validate(ToolDefinition definition, Map<String, Object?> args) {
    return _value(definition.schema, args, r'\$');
  }

  String? _value(Map<String, Object?> schema, Object? value, String path) {
    final Object? enumValue = schema['enum'];
    if (enumValue is List && !enumValue.contains(value)) {
      return '$path 必须是枚举值之一';
    }
    final String? type = schema['type'] as String?;
    if (type == 'object') {
      if (value is! Map) return '$path 必须是对象';
      final Map<String, Object?> properties =
          (schema['properties'] as Map?)
              ?.map((Object? k, Object? v) => MapEntry(k.toString(), v))
              .cast<String, Object?>() ??
          <String, Object?>{};
      final List<Object?> required = (schema['required'] as List?) ?? const [];
      for (final Object? key in required) {
        if (!value.containsKey(key)) return '$path 缺少必填参数 $key';
      }
      for (final MapEntry<Object?, Object?> entry in value.entries) {
        final Object? child = properties[entry.key.toString()];
        if (child is Map) {
          final String? error = _value(
            child.cast<String, Object?>(),
            entry.value,
            '$path.${entry.key}',
          );
          if (error != null) return error;
        }
      }
      return null;
    }
    final bool valid = switch (type) {
      'string' => value is String,
      'number' => value is num,
      'integer' => value is int,
      'boolean' => value is bool,
      'array' => value is List,
      null => true,
      _ => false,
    };
    return valid ? null : '$path 类型不匹配，应为 $type';
  }
}
