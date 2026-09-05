import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../ai/messages.dart';
import '../ai/provider_api.dart';

class ContextBudget {
  const ContextBudget({this.maxInputTokens, this.maxOutputTokensTotal});
  final int? maxInputTokens;
  final int? maxOutputTokensTotal;
}

class AgentContext {
  const AgentContext({
    required this.systemPromptStable,
    this.systemPromptDynamic = '',
    required this.tools,
    required this.messages,
    this.budget = const ContextBudget(),
    this.contextVersion = '1',
  });
  final String systemPromptStable;
  final String systemPromptDynamic;
  final List<ToolDefinition> tools;
  final List<ChatMessageModel> messages;
  final ContextBudget budget;
  final String contextVersion;
}

class CanonicalContext {
  const CanonicalContext(this.json, this.prefixHash);
  final String json;
  final String prefixHash;
}

CanonicalContext canonicalizeContext(AgentContext context) {
  final List<Map<String, Object?>> tools = context.tools
      .map(
        (ToolDefinition tool) => <String, Object?>{
          'name': tool.name,
          'description': tool.description,
          'version': tool.version,
          'schema': _sorted(tool.schema),
        },
      )
      .toList();
  final String prefix = jsonEncode(<String, Object?>{
    'version': context.contextVersion,
    'system': context.systemPromptStable,
    'tools': tools,
  });
  final String body = jsonEncode(<String, Object?>{
    'prefix': prefix,
    'dynamic': context.systemPromptDynamic,
    'messages': context.messages.map(_message).toList(),
  });
  return CanonicalContext(body, sha256.convert(utf8.encode(prefix)).toString());
}

Object? _sorted(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((Object? key) => key.toString()).toList()
      ..sort();
    return <String, Object?>{
      for (final String key in keys) key: _sorted(value[key]),
    };
  }
  if (value is List) return value.map(_sorted).toList();
  return value;
}

Map<String, Object?> _message(ChatMessageModel message) => <String, Object?>{
  'role': message.role.name,
  'parts': message.parts
      .map(
        (ContentPart part) => part is TextPart
            ? <String, Object?>{'text': part.text}
            : part is ToolCallPart
            ? <String, Object?>{
                'id': part.id,
                'name': part.name,
                'arguments': _sorted(part.arguments),
              }
            : <String, Object?>{'type': part.runtimeType.toString()},
      )
      .toList(),
};
