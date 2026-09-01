/// 三个 API 适配器的统一契约（实施 TODO §4-1）。
library;

import '../core/cancellation_token.dart';
import 'messages.dart';
import 'model_catalog.dart';
import 'stream_event.dart';

/// 工具定义，进请求体的 `tools` 字段。
///
/// [schema] 是受限的 JSON Schema 子集：object / string / number / integer /
/// boolean / array / enum / required。**不含** oneOf / anyOf / $ref / 递归
/// ——协议 §6.2 要求用各家都支持的子集（§7-2）。
class ToolDefinition {
  const ToolDefinition({
    required this.name,
    required this.description,
    required this.schema,
  });

  final String name;

  /// 进 prompt，影响缓存前缀，改动要谨慎（§7.1）。
  final String description;

  final Map<String, Object?> schema;
}

/// 一次请求。
class ProviderRequest {
  const ProviderRequest({
    required this.model,
    required this.messages,
    this.systemPrompt,
    this.tools = const <ToolDefinition>[],
    this.maxOutputTokens,
    this.temperature,
    this.thinkingBudget,
    this.sessionId,
    this.parallelToolCalls = true,
  });

  final ModelSpec model;

  /// 历史消息。不含 system——system 在 anthropic 是顶层字段，
  /// 塞进消息列表会被当成普通轮次。
  final List<ChatMessageModel> messages;

  final String? systemPrompt;

  /// 已按名字典序排好的工具列表（§6-6）。适配器不再排序：
  /// 排序职责在 `ToolRegistry`，这里重复排等于两处实现。
  final List<ToolDefinition> tools;

  final int? maxOutputTokens;

  /// null 表示不发这个字段。o 系列必须省略（`supportsTemperature`）。
  final double? temperature;

  /// anthropic 的 `budget_tokens`，或 openai `reasoning_effort` 的换算源。
  /// null 表示不开思考。
  final int? thinkingBudget;

  /// 会话 id，填进 openai 的 `prompt_cache_key`（§6-10）。
  final String? sessionId;

  final bool parallelToolCalls;
}

/// API 适配器。
abstract class ProviderApi {
  /// 流式请求。
  ///
  /// **永不抛异常、永不 addError**（§4-2）。失败编码进最终的 [StreamDone]：
  /// `stopReason` 为 `error` / `aborted`，`errorMessage` 带说明。
  ///
  /// 这条契约是从 pi 抄的，理由是上层 loop 只需处理一种失败路径，
  /// 不必同时接 try/catch 和事件——两条路径必然有一条会被漏掉。
  Stream<StreamEvent> stream(ProviderRequest request, CancellationToken token);

  /// 无工具的一次性调用，给标题生成和压缩摘要用（§4-1）。
  ///
  /// 内部就是消费 [stream] 到 [StreamDone]，所以同样不抛——
  /// 失败时返回的消息带 `stopReason: error`。
  Future<ChatMessageModel> streamSimple(
    ProviderRequest request,
    CancellationToken token,
  ) async {
    ChatMessageModel? last;
    await for (final StreamEvent event in stream(request, token)) {
      last = event.message;
    }
    return last ??
        const ChatMessageModel(
          role: MessageRole.assistant,
          parts: <ContentPart>[],
          stopReason: StopReason.error,
          errorMessage: '流没有产生任何事件',
        );
  }
}
