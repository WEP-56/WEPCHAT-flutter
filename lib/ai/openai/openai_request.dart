/// openai-completions 的请求体构造（实施 TODO §4-7、§6-5）。
///
/// **字段顺序影响 prompt cache，勿动。** 理由见 `anthropic_request.dart`
/// 顶部的说明——Dart 的 Map 是插入序，赋值语句的先后决定请求字节。
library;

import 'dart:convert';

import '../messages.dart';
import '../model_compat.dart';
import '../provider_api.dart';

Map<String, Object?> buildCompletionsRequest(ProviderRequest req) {
  final ModelCompat compat = req.model.compat;
  final Map<String, Object?> body = <String, Object?>{};

  // 1. model —— 永不变
  body['model'] = req.model.id;

  // 2. messages —— system 在 openai 是消息列表的第一条，不是顶层字段
  body['messages'] = _buildMessages(req);

  // 3. tools —— 已按名排序（§6-6），适配器不再排
  if (req.tools.isNotEmpty) {
    body['tools'] = _buildTools(req.tools);

    // 兼容端点一轮只回一个 tool_call 时传 true 会 400，所以由标记决定。
    // 只在支持时显式发：省略与 false 语义不同（省略=服务端默认）。
    if (compat.supportsParallelToolCalls && !req.parallelToolCalls) {
      body['parallel_tool_calls'] = false;
    }
  }

  // 4. max_tokens 的字段名按模型走：o 系列与 gpt-5 只认
  //    max_completion_tokens，传 max_tokens 直接 400（ModelCompat 的注释）。
  body[compat.maxTokensField] = req.maxOutputTokens ?? req.model.maxOutputTokens;

  // 5. temperature —— o 系列拒绝这个字段，必须省略（传 1.0 也不行）
  if (req.temperature != null && compat.supportsTemperature) {
    body['temperature'] = req.temperature;
  }

  // 6. 思考开关。三家的传法完全不同，没有共同子集。
  _applyThinking(body, req);

  // 7. prompt_cache_key 填会话 id，把同一会话路由到同一台缓存副本（§6-10）。
  //    截断到 64 字符是 OpenAI 的上限；ULID 是 26 字符，实际不会触发。
  final String? sessionId = req.sessionId;
  if (compat.supportsPromptCacheKey && sessionId != null) {
    body['prompt_cache_key'] =
        sessionId.length <= 64 ? sessionId : sessionId.substring(0, 64);
  }

  body['stream'] = true;

  // usage 在流式下默认不返回，要显式要。不给这个字段就永远看不到用量，
  // 而用量是 M1 的验收项之一（§10-5）。
  body['stream_options'] = <String, Object?>{'include_usage': true};

  return body;
}

void _applyThinking(Map<String, Object?> body, ProviderRequest req) {
  final int? budget = req.thinkingBudget;

  switch (req.model.compat.thinking) {
    case ThinkingFormat.openaiReasoningEffort:
      if (budget == null) return;
      body['reasoning_effort'] = _effortFor(budget);

    case ThinkingFormat.qwenEnableThinking:
      // Qwen3 要显式开关；关闭时也要发 false，否则部分模型默认开着。
      body['enable_thinking'] = budget != null;

    case ThinkingFormat.deepseekReasoningContent:
      // 请求侧没有开关，模型自己决定要不要思考。
      break;

    case ThinkingFormat.anthropicThinking:
    case ThinkingFormat.none:
      break;
  }
}

/// budget token 数换算成 OpenAI 的三档。
///
/// 分界点取得宽松：这三档在服务端是模糊的努力程度，不是精确预算，
/// 精确映射没有意义。
String _effortFor(int budget) {
  if (budget <= 4096) return 'low';
  if (budget <= 16384) return 'medium';
  return 'high';
}

List<Map<String, Object?>> _buildTools(List<ToolDefinition> tools) {
  return <Map<String, Object?>>[
    for (final ToolDefinition tool in tools)
      <String, Object?>{
        'type': 'function',
        'function': <String, Object?>{
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.schema,
        },
      },
  ];
}

/// 消息列表。
///
/// 和 anthropic 的三处结构差异：
/// - system 是列表里的一条消息（角色名按 `supportsDeveloperRole` 选）
/// - tool_call 挂在 assistant 消息的 `tool_calls` 字段上，不是 content block
/// - tool_result 是独立的 `role: tool` 消息，一个结果一条
List<Map<String, Object?>> _buildMessages(ProviderRequest req) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];

  final String? system = req.systemPrompt;
  if (system != null && system.isNotEmpty) {
    out.add(<String, Object?>{
      'role': req.model.compat.supportsDeveloperRole ? 'developer' : 'system',
      'content': system,
    });
  }

  for (final ChatMessageModel msg in req.messages) {
    switch (msg.role) {
      // 上游应该已经把 system 提到 systemPrompt 了；真混进来就当普通
      // system 消息发，不静默丢掉（AGENTS.md §1.3）。
      case MessageRole.system:
        out.add(<String, Object?>{'role': 'system', 'content': msg.text});

      case MessageRole.user:
        out.add(_buildUserMessage(msg));

      case MessageRole.assistant:
        out.add(_buildAssistantMessage(msg));

      case MessageRole.tool:
        // 一个 tool_result 一条消息，不能合并——tool_call_id 是一对一的。
        for (final ContentPart part in msg.parts) {
          if (part is! ToolResultPart) continue;
          out.add(_buildToolMessage(part, req.model.compat));
        }
    }
  }

  return out;
}

/// user 消息。纯文本时 content 是字符串，带图片时是 part 数组。
///
/// 两种形状都合法，但字符串形状的字节更短且更多兼容端点认它，
/// 所以没图片时不升级成数组。
Map<String, Object?> _buildUserMessage(ChatMessageModel msg) {
  final List<ImagePart> images = msg.parts.whereType<ImagePart>().toList();

  if (images.isEmpty) {
    return <String, Object?>{'role': 'user', 'content': msg.text};
  }

  final List<Map<String, Object?>> parts = <Map<String, Object?>>[];
  for (final ContentPart part in msg.parts) {
    switch (part) {
      case TextPart(:final String text):
        if (text.isEmpty) break;
        parts.add(<String, Object?>{'type': 'text', 'text': text});

      case ImagePart(:final String base64Data, :final String mimeType):
        // openai 要 data URI，不是 anthropic 那样的 source 对象。
        parts.add(<String, Object?>{
          'type': 'image_url',
          'image_url': <String, Object?>{
            'url': 'data:$mimeType;base64,$base64Data',
          },
        });

      case ThinkingPart():
      case ToolCallPart():
      case ToolResultPart():
        break;
    }
  }
  return <String, Object?>{'role': 'user', 'content': parts};
}

/// assistant 消息。
///
/// 不回传 thinking：openai 的 reasoning 内容本来就不返回（只计入
/// `reasoning_tokens`），deepseek 的 `reasoning_content` 官方明确要求
/// **不要**在下一轮回传，回传会 400。所以这里一律丢弃 [ThinkingPart]。
Map<String, Object?> _buildAssistantMessage(ChatMessageModel msg) {
  final Map<String, Object?> out = <String, Object?>{'role': 'assistant'};

  final String text = msg.text;
  final List<ToolCallPart> calls = msg.toolCalls;

  // content 即使为空也要给：部分兼容端点缺这个 key 会报字段缺失。
  // 只调工具不说话时用 null 而不是空串——空串在某些端点会被当成
  // "模型说了句空话"而触发内容过滤。
  out['content'] = text.isEmpty ? null : text;

  if (calls.isNotEmpty) {
    out['tool_calls'] = <Map<String, Object?>>[
      for (final ToolCallPart call in calls)
        <String, Object?>{
          'id': call.id,
          'type': 'function',
          'function': <String, Object?>{
            'name': call.name,
            // arguments 是**字符串**，不是对象。这是 openai 的形状，
            // 传对象会 400。
            'arguments': _encodeArguments(call.arguments),
          },
        },
    ];
  }

  return out;
}

/// 空参数编码成 `{}` 而不是空串：空串不是合法 JSON，部分端点会拒。
String _encodeArguments(Map<String, Object?> arguments) {
  return arguments.isEmpty ? '{}' : jsonEncode(arguments);
}

Map<String, Object?> _buildToolMessage(ToolResultPart part, ModelCompat compat) {
  final Map<String, Object?> out = <String, Object?>{
    'role': 'tool',
    'tool_call_id': part.callId,
  };
  // 少数自建 vLLM / Ollama 兼容层要求带 name；官方端点不需要，多传会改变
  // 请求字节（影响缓存），所以由标记决定（ModelCompat 的注释）。
  if (compat.requiresToolResultName) {
    out['name'] = part.name;
  }
  out['content'] = part.content;
  return out;
}
