/// 领域层的消息模型（实施 TODO §0.1）。
///
/// 和 `lib/models/chat.dart` 的关系：那边是展示模型（`time` 是 `'14:32'`
/// 字符串、`isUser` 是 bool），这边是真实领域模型。UI 的展示模型由这边派生，
/// 不是反过来——所以这个文件不 import flutter，也不 import models/。
library;

/// 消息角色。
///
/// 不用 bool `isUser`：tool 结果既不是 user 也不是 assistant，
/// 而 system 在 anthropic 是顶层字段、在 openai 是消息，得能区分。
enum MessageRole { system, user, assistant, tool }

/// 停止原因。
///
/// `length` 单独一档不是冗余：它意味着最后一个 tool call 的 arguments
/// 被截断了，整批工具都不能执行（§5-9）。
/// `error` / `aborted` 的轮次在下次请求时要整轮丢掉（§6-14）。
enum StopReason {
  /// 模型自然说完。
  stop,

  /// 模型请求调用工具。
  toolUse,

  /// 撞上 max_tokens，输出被截断。
  length,

  /// 请求失败（网络、API 报错）。
  error,

  /// 用户中断。
  aborted,
}

/// 内容块。一条消息由若干块组成。
sealed class ContentPart {
  const ContentPart();
}

/// 纯文本。
class TextPart extends ContentPart {
  const TextPart(this.text);

  final String text;
}

/// 思考内容（reasoning / thinking）。
///
/// [signature] 是 anthropic 的签名，回传时**必须原样带回**，改一个字节
/// 就报错（§4-9）。其它家没有签名，留 null。
///
/// [modelId] 记下是哪个模型产出的：换模型后要丢弃别人的 thinking 块
/// （§6-15），靠这个字段判断，不靠猜。
class ThinkingPart extends ContentPart {
  const ThinkingPart(this.text, {this.signature, this.modelId});

  final String text;
  final String? signature;
  final String? modelId;
}

/// 模型请求调用工具。
///
/// [arguments] 是**已经收全并解析过**的参数。流式过程中的字符串增量
/// 由适配器内部拼，不暴露到这一层——中途 parse 一定失败（§4-7）。
class ToolCallPart extends ContentPart {
  const ToolCallPart({
    required this.id,
    required this.name,
    required this.arguments,
  });

  final String id;
  final String name;
  final Map<String, Object?> arguments;
}

/// 工具执行结果，回传给模型。
///
/// [name] 只在 `ModelCompat.requiresToolResultName` 的端点才写进请求体
/// （§4.2），但这一层总是记着，省得回传时再去查是哪个工具。
class ToolResultPart extends ContentPart {
  const ToolResultPart({
    required this.callId,
    required this.name,
    required this.content,
    this.isError = false,
  });

  final String callId;
  final String name;
  final String content;
  final bool isError;
}

/// 图片输入。
///
/// 存 base64 而不是路径：请求体要的是字节，而路径在 isolate 之间传递、
/// 在历史回放时都可能已经失效。非视觉模型下由 `transformMessages` 降级
/// 成一句文字说明（§6.4）。
class ImagePart extends ContentPart {
  const ImagePart({required this.base64Data, required this.mimeType});

  final String base64Data;
  final String mimeType;
}

/// token 用量。
///
/// [cacheReadTokens] / [cacheWriteTokens] 必须能单独看到：缓存有没有生效
/// 是 §6 那一整节工作的唯一验证手段，界面上也要显示（§6-12）。
class TokenUsage {
  const TokenUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;
  final int cacheReadTokens;
  final int cacheWriteTokens;
  final int reasoningTokens;

  /// 计费口径的总量。缓存读的部分单价不同，这里不折算——
  /// 折算是价格表的事（M3 的成本统计），不是用量模型的事。
  int get totalTokens => inputTokens + outputTokens;

  bool get isEmpty =>
      inputTokens == 0 &&
      outputTokens == 0 &&
      cacheReadTokens == 0 &&
      cacheWriteTokens == 0;

  TokenUsage operator +(TokenUsage other) {
    return TokenUsage(
      inputTokens: inputTokens + other.inputTokens,
      outputTokens: outputTokens + other.outputTokens,
      cacheReadTokens: cacheReadTokens + other.cacheReadTokens,
      cacheWriteTokens: cacheWriteTokens + other.cacheWriteTokens,
      reasoningTokens: reasoningTokens + other.reasoningTokens,
    );
  }

  @override
  String toString() =>
      'TokenUsage(in: $inputTokens, out: $outputTokens, '
      'cacheRead: $cacheReadTokens, cacheWrite: $cacheWriteTokens)';
}

/// 一条消息。
class ChatMessageModel {
  const ChatMessageModel({
    required this.role,
    required this.parts,
    this.stopReason,
    this.usage = const TokenUsage(),
    this.modelId,
    this.errorMessage,
  });

  /// 便利构造：纯文本用户消息。
  factory ChatMessageModel.user(String text) {
    return ChatMessageModel(
      role: MessageRole.user,
      parts: <ContentPart>[TextPart(text)],
    );
  }

  /// 便利构造：system prompt。
  factory ChatMessageModel.system(String text) {
    return ChatMessageModel(
      role: MessageRole.system,
      parts: <ContentPart>[TextPart(text)],
    );
  }

  final MessageRole role;
  final List<ContentPart> parts;

  /// 只有 assistant 消息有停止原因。
  final StopReason? stopReason;
  final TokenUsage usage;

  /// 产出这条消息的模型。thinking 块的归属判断要用（§6-15）。
  final String? modelId;

  /// [stopReason] 为 [StopReason.error] 时的说明。
  ///
  /// 走这个字段而不是抛异常：适配器的 `stream` 永不抛、永不 addError，
  /// 失败编码进最终事件（§4-2）。
  final String? errorMessage;

  /// 拼起来的文本，不含 thinking。
  String get text {
    final StringBuffer buf = StringBuffer();
    for (final ContentPart part in parts) {
      if (part is TextPart) buf.write(part.text);
    }
    return buf.toString();
  }

  /// 思考内容。
  String get thinkingText {
    final StringBuffer buf = StringBuffer();
    for (final ContentPart part in parts) {
      if (part is ThinkingPart) buf.write(part.text);
    }
    return buf.toString();
  }

  List<ToolCallPart> get toolCalls =>
      parts.whereType<ToolCallPart>().toList(growable: false);

  bool get hasToolCalls => parts.any((ContentPart p) => p is ToolCallPart);

  /// 这一轮是否可以进下次请求的历史。
  ///
  /// error / aborted 的轮次要整轮丢掉（§6-14）：内容不完整，
  /// 留着会让模型看到半句话或没有结果的 tool_use。
  bool get isUsableInHistory =>
      stopReason != StopReason.error && stopReason != StopReason.aborted;

  ChatMessageModel copyWith({
    MessageRole? role,
    List<ContentPart>? parts,
    StopReason? stopReason,
    TokenUsage? usage,
    String? modelId,
    String? errorMessage,
  }) {
    return ChatMessageModel(
      role: role ?? this.role,
      parts: parts ?? this.parts,
      stopReason: stopReason ?? this.stopReason,
      usage: usage ?? this.usage,
      modelId: modelId ?? this.modelId,
      errorMessage: errorMessage ?? this.errorMessage,
    );
  }
}
