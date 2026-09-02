/// openai-responses 的请求体构造（实施 TODO §4-8）。
///
/// **字段顺序影响 prompt cache，勿动。**
///
/// 和 completions 的四处结构差异，是这个文件不能复用那边的原因：
/// - 历史叫 `input` 而不是 `messages`，system 叫 `instructions` 且是顶层字段
/// - 工具定义是平铺的（`{type, name, description, parameters}`），不套 function
/// - 工具调用回传是 `function_call` 项，结果是 `function_call_output` 项
/// - `store: false` 必须显式设，否则请求被留在服务端
library;

import 'dart:convert';

import '../messages.dart';
import '../model_compat.dart';
import '../provider_api.dart';

Map<String, Object?> buildResponsesRequest(ProviderRequest req) {
  final ModelCompat compat = req.model.compat;
  final Map<String, Object?> body = <String, Object?>{};

  // 1. model —— 永不变
  body['model'] = req.model.id;

  // 2. instructions —— system 在这里是顶层字段（同 anthropic，不同 completions）
  final String? system = req.systemPrompt;
  if (system != null && system.isNotEmpty) {
    body['instructions'] = system;
  }

  // 3. input —— 历史
  body['input'] = _buildInput(req);

  // 4. tools —— 已按名排序（§6-6）
  if (req.tools.isNotEmpty) {
    body['tools'] = _buildTools(req.tools);
    if (compat.supportsParallelToolCalls && !req.parallelToolCalls) {
      body['parallel_tool_calls'] = false;
    }
  }

  // 5. 输出上限。字段名和 completions 都不一样。
  body['max_output_tokens'] = req.maxOutputTokens ?? req.model.maxOutputTokens;

  if (req.temperature != null && compat.supportsTemperature) {
    body['temperature'] = req.temperature;
  }

  // 6. reasoning。responses 端点上思考是个对象，不是 completions 的
  //    单字段 reasoning_effort。
  if (req.thinkingBudget != null &&
      compat.thinking == ThinkingFormat.openaiReasoningEffort) {
    body['reasoning'] = <String, Object?>{
      'effort': _effortFor(req.thinkingBudget!),
    };
  }

  final String? sessionId = req.sessionId;
  if (compat.supportsPromptCacheKey && sessionId != null) {
    body['prompt_cache_key'] = sessionId.length <= 64
        ? sessionId
        : sessionId.substring(0, 64);
  }

  // 7. store: false —— 必须显式设（§4-8）。省略等于让服务端留存这次请求，
  //    对一个本地聊天客户端来说那是意料之外的数据外流。
  body['store'] = false;

  body['stream'] = true;

  return body;
}

String _effortFor(int budget) {
  if (budget <= 4096) return 'low';
  if (budget <= 16384) return 'medium';
  return 'high';
}

/// 工具定义是平铺的，不像 completions 那样套一层 `function`。
List<Map<String, Object?>> _buildTools(List<ToolDefinition> tools) {
  return <Map<String, Object?>>[
    for (final ToolDefinition tool in tools)
      <String, Object?>{
        'type': 'function',
        'name': tool.name,
        'description': tool.description,
        'parameters': tool.schema,
      },
  ];
}

/// input 项列表。
///
/// 消息项用 `{role, content}`；工具调用与结果是**平级的独立项**，
/// 不挂在消息上——这是 responses 和 completions 最大的结构差异。
List<Map<String, Object?>> _buildInput(ProviderRequest req) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];

  for (final ChatMessageModel msg in req.messages) {
    switch (msg.role) {
      case MessageRole.system:
        // 上游应该已经提到 instructions 了；混进来就按 system 消息发。
        out.add(<String, Object?>{'role': 'system', 'content': msg.text});

      case MessageRole.user:
        out.add(_buildUserItem(msg));

      case MessageRole.assistant:
        out.addAll(_buildAssistantItems(msg));

      case MessageRole.tool:
        for (final ContentPart part in msg.parts) {
          if (part is! ToolResultPart) continue;
          out.add(<String, Object?>{
            'type': 'function_call_output',
            'call_id': part.callId,
            'output': part.content,
          });
        }
    }
  }

  return out;
}

Map<String, Object?> _buildUserItem(ChatMessageModel msg) {
  final bool hasImage = msg.parts.any((ContentPart p) => p is ImagePart);
  if (!hasImage) {
    return <String, Object?>{'role': 'user', 'content': msg.text};
  }

  final List<Map<String, Object?>> parts = <Map<String, Object?>>[];
  for (final ContentPart part in msg.parts) {
    switch (part) {
      case TextPart(:final String text):
        if (text.isEmpty) break;
        // 类型名是 input_text，不是 completions 的 text。
        parts.add(<String, Object?>{'type': 'input_text', 'text': text});

      case ImagePart(:final String base64Data, :final String mimeType):
        parts.add(<String, Object?>{
          'type': 'input_image',
          'image_url': 'data:$mimeType;base64,$base64Data',
        });

      case ThinkingPart():
      case ToolCallPart():
      case ToolResultPart():
        break;
    }
  }
  return <String, Object?>{'role': 'user', 'content': parts};
}

/// assistant 的一条消息可能展开成多个 input 项：正文一项，每个工具调用各一项。
///
/// thinking 不回传：`store: false` 下服务端没有留存推理项，回传本地拼的
/// reasoning 项会因为缺 id 被拒。
List<Map<String, Object?>> _buildAssistantItems(ChatMessageModel msg) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];

  final String text = msg.text;
  if (text.isNotEmpty) {
    out.add(<String, Object?>{
      'role': 'assistant',
      'content': <Map<String, Object?>>[
        <String, Object?>{'type': 'output_text', 'text': text},
      ],
    });
  }

  for (final ToolCallPart call in msg.toolCalls) {
    out.add(<String, Object?>{
      'type': 'function_call',
      'call_id': call.id,
      'name': call.name,
      // 同 completions：arguments 是字符串，不是对象。
      'arguments': call.arguments.isEmpty ? '{}' : jsonEncode(call.arguments),
    });
  }

  return out;
}
