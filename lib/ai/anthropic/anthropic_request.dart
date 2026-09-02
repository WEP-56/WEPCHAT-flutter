/// anthropic-messages 的请求体构造（实施 TODO §4-9、§6-5）。
///
/// **字段顺序影响 prompt cache，勿动。**
///
/// Dart 的 Map 是插入序，`jsonEncode` 按插入序输出——也就是说下面这些
/// 赋值语句的先后决定了请求的字节。重构时挪一行就会打断所有用户的缓存，
/// 而且不会有任何报错，没人会发现（§6.2）。
library;

import '../messages.dart';
import '../model_compat.dart';
import '../provider_api.dart';

/// cache_control 落点上限。超了 API 直接报错（§6-9）。
const int _kMaxCacheBreakpoints = 4;

Map<String, Object?> buildAnthropicRequest(ProviderRequest req) {
  final Map<String, Object?> body = <String, Object?>{};

  // 1. model —— 永不变
  body['model'] = req.model.id;

  // 2. max_tokens —— anthropic 是必填字段
  body['max_tokens'] = req.maxOutputTokens ?? req.model.maxOutputTokens;

  // 3. system —— 顶层字段，不是消息（§4-9）
  if (req.systemPrompt != null && req.systemPrompt!.isNotEmpty) {
    body['system'] = _buildSystem(req);
  }

  // 4. tools —— 已按名排序（§6-6），适配器不再排
  if (req.tools.isNotEmpty) {
    body['tools'] = _buildTools(req);
  }

  // 5. thinking
  if (req.thinkingBudget != null &&
      req.model.compat.thinking == ThinkingFormat.anthropicThinking) {
    body['thinking'] = <String, Object?>{
      'type': 'enabled',
      'budget_tokens': req.thinkingBudget,
    };
  }

  // 6. temperature —— 开了 thinking 时 anthropic 要求 temperature 必须是 1，
  //    干脆省略（省略等于默认 1）。
  if (req.temperature != null &&
      req.model.compat.supportsTemperature &&
      req.thinkingBudget == null) {
    body['temperature'] = req.temperature;
  }

  // 7. messages —— 历史在前、本轮在后，易变信息在最末（§6.1）
  body['messages'] = _buildMessages(req);

  body['stream'] = true;

  return body;
}

/// system 块。
///
/// 拆成两块（产品身份 / 工具与记忆摘要）在这一版没有必要——调用方给的是
/// 一整段文本。cache_control 挂在末尾，对应 §6.1 的落点 1。
List<Map<String, Object?>> _buildSystem(ProviderRequest req) {
  final Map<String, Object?> block = <String, Object?>{
    'type': 'text',
    'text': req.systemPrompt,
  };
  if (req.model.compat.cache == CacheControlFormat.anthropic) {
    block['cache_control'] = <String, Object?>{'type': 'ephemeral'};
  }
  return <Map<String, Object?>>[block];
}

/// 工具定义。cache_control 挂最后一个，对应 §6.1 的落点 2。
List<Map<String, Object?>> _buildTools(ProviderRequest req) {
  final List<Map<String, Object?>> tools = <Map<String, Object?>>[];

  for (int i = 0; i < req.tools.length; i++) {
    final ToolDefinition tool = req.tools[i];
    final Map<String, Object?> entry = <String, Object?>{
      'name': tool.name,
      'description': tool.description,
      'input_schema': tool.schema,
    };
    final bool isLast = i == req.tools.length - 1;
    if (isLast && req.model.compat.cache == CacheControlFormat.anthropic) {
      entry['cache_control'] = <String, Object?>{'type': 'ephemeral'};
    }
    tools.add(entry);
  }
  return tools;
}

/// 消息列表。
///
/// cache_control 挂最后一条 user 消息的最后一个 block，对应 §6.1 的落点 3。
/// system(1) + tools(1) + 最后一条 user(1) = 3 个，在四个上限内。
List<Map<String, Object?>> _buildMessages(ProviderRequest req) {
  final List<Map<String, Object?>> out = <Map<String, Object?>>[];
  final bool useCache = req.model.compat.cache == CacheControlFormat.anthropic;

  final int lastUserIndex = _lastIndexWhere(
    req.messages,
    (ChatMessageModel m) => m.role == MessageRole.user,
  );

  int breakpoints = useCache ? 2 : 0; // system + tools 已经用掉两个

  for (int i = 0; i < req.messages.length; i++) {
    final ChatMessageModel msg = req.messages[i];
    if (msg.role == MessageRole.system) continue; // system 走顶层字段

    final bool markCache =
        useCache && i == lastUserIndex && breakpoints < _kMaxCacheBreakpoints;

    final List<Map<String, Object?>> blocks = _buildBlocks(
      msg,
      markLastWithCache: markCache,
    );
    if (blocks.isEmpty) continue; // 空消息（被降级掉的图片等），跳过

    if (markCache) breakpoints++;

    out.add(<String, Object?>{'role': _roleName(msg.role), 'content': blocks});
  }

  return out;
}

/// 一条消息的 content blocks。
List<Map<String, Object?>> _buildBlocks(
  ChatMessageModel msg, {
  required bool markLastWithCache,
}) {
  final List<Map<String, Object?>> blocks = <Map<String, Object?>>[];

  for (final ContentPart part in msg.parts) {
    switch (part) {
      case TextPart(:final String text):
        if (text.isEmpty) break;
        blocks.add(<String, Object?>{'type': 'text', 'text': text});

      case ThinkingPart(:final String text, :final String? signature):
        // signature 必须原样带回，改一个字节就报错（§4-9）。
        // 没有 signature 的 thinking 块不能回传——那是别家模型产出的，
        // 由 transformMessages 在上游丢掉，这里再兜一层。
        if (signature == null) break;
        blocks.add(<String, Object?>{
          'type': 'thinking',
          'thinking': text,
          'signature': signature,
        });

      case ToolCallPart(
        :final String id,
        :final String name,
        :final Map<String, Object?> arguments,
      ):
        blocks.add(<String, Object?>{
          'type': 'tool_use',
          'id': id,
          'name': name,
          'input': arguments,
        });

      case ToolResultPart(
        :final String callId,
        :final String content,
        :final bool isError,
      ):
        // tool_result 是 user 消息里的 block，不是独立角色（§4-9）。
        final Map<String, Object?> block = <String, Object?>{
          'type': 'tool_result',
          'tool_use_id': callId,
          'content': content,
        };
        if (isError) block['is_error'] = true;
        blocks.add(block);

      case ImagePart(:final String base64Data, :final String mimeType):
        blocks.add(<String, Object?>{
          'type': 'image',
          'source': <String, Object?>{
            'type': 'base64',
            'media_type': mimeType,
            'data': base64Data,
          },
        });
    }
  }

  if (markLastWithCache && blocks.isNotEmpty) {
    blocks.last['cache_control'] = <String, Object?>{'type': 'ephemeral'};
  }

  return blocks;
}

/// tool 角色在 anthropic 里不存在：tool_result 是 user 消息的 block。
String _roleName(MessageRole role) {
  return switch (role) {
    MessageRole.assistant => 'assistant',
    MessageRole.user || MessageRole.tool => 'user',
    MessageRole.system => 'user', // 不该走到：system 已在上游过滤
  };
}

int _lastIndexWhere<T>(List<T> list, bool Function(T) test) {
  for (int i = list.length - 1; i >= 0; i--) {
    if (test(list[i])) return i;
  }
  return -1;
}
