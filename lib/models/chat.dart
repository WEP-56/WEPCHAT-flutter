import 'content.dart';
import 'tool_call.dart';
import 'workspace.dart';

/// 用户上传的附件。
class Attachment {
  const Attachment({
    required this.name,
    required this.size,
    required this.kind,
  });

  final String name;
  final String size;
  final FileKind kind;
}

/// `gen_image` / `edit_image` 的产物。
class ImageResult {
  const ImageResult({required this.file, required this.meta});

  /// 工作区相对路径。
  final String file;

  /// 展示用的规格文本，例如 `1024×576 · PNG`。
  final String meta;
}

/// HTML 产物引用，聊天里以可预览卡片呈现。
class HtmlRef {
  const HtmlRef({required this.file, required this.title, required this.desc});

  final String file;
  final String title;
  final String desc;
}

/// 聊天里一条消息的角色（实施 TODO §10-2）。
///
/// 不用 bool `isUser`：加上工具结果之后就有三种了，而 bool 只能表达两种。
/// 换成枚举是 M2 做的——越晚改牵连越多。
enum ChatRole { user, assistant, toolResult }

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.role,
    required this.time,
    this.seq = 0,
    this.attachments = const <Attachment>[],
    this.tools = const <ToolCall>[],
    this.blocks = const <ContentBlock>[],
    this.images = const <ImageResult>[],
    this.files = const <String>[],
    this.html,
    this.isStreaming = false,
    this.rawText = '',
    this.usage,
    this.elapsed,
  });

  final String id;
  final ChatRole role;

  bool get isUser => role == ChatRole.user;

  /// 这条消息在会话日志里的 `seq`，0 表示还没落库（流式草稿）。
  ///
  /// 「编辑重发」要往存储里写一条覆盖 `seq >= n` 的截断标记（存储设计 §8），
  /// 而 [id] 是 ULID、不表示顺序，所以序号得一路带到界面上。
  final int seq;

  /// 展示用时间文本，例如 `14:32`。
  final String time;

  final List<Attachment> attachments;
  final List<ToolCall> tools;
  final List<ContentBlock> blocks;
  final List<ImageResult> images;

  /// 本轮产出的工作区文件相对路径。
  final List<String> files;

  final HtmlRef? html;

  /// 助手消息尚在生成中：显示光标动画并允许中断。
  final bool isStreaming;

  /// 未经解析的原始文本，供「复制」与「编辑」用。
  ///
  /// 从 blocks 反推回 Markdown 源码是有损的（解析器丢掉了空行数量、
  /// 列表符号种类这些信息），所以原样留一份。
  final String rawText;

  /// 本条消息的用量。只有助手消息有（实施 TODO §10-5）。
  final MessageUsage? usage;

  /// 这一轮从发出请求到结束的耗时。
  final Duration? elapsed;

  ChatMessage copyWith({
    List<ToolCall>? tools,
    List<ContentBlock>? blocks,
    List<ImageResult>? images,
    List<String>? files,
    HtmlRef? html,
    bool? isStreaming,
    String? rawText,
    MessageUsage? usage,
    Duration? elapsed,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      time: time,
      seq: seq,
      attachments: attachments,
      tools: tools ?? this.tools,
      blocks: blocks ?? this.blocks,
      images: images ?? this.images,
      files: files ?? this.files,
      html: html ?? this.html,
      isStreaming: isStreaming ?? this.isStreaming,
      rawText: rawText ?? this.rawText,
      usage: usage ?? this.usage,
      elapsed: elapsed ?? this.elapsed,
    );
  }
}

/// 一条助手消息的用量，显示在消息操作栏上（实施 TODO §10-5、§6-12）。
///
/// 和 `ai/messages.dart` 的 `TokenUsage` 分开：那个是协议层的累积器，
/// 这个是展示模型，只留界面要显示的几项。
class MessageUsage {
  const MessageUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheReadTokens = 0,
    this.cacheWriteTokens = 0,
    this.reasoningTokens = 0,
  });

  final int inputTokens;
  final int outputTokens;

  /// 缓存命中 / 写入分开显示，且排在输出前面：缓存有没有生效是 §6 那一整节
  /// 工作的唯一验证手段，混进总量里就看不出来了。
  final int cacheReadTokens;
  final int cacheWriteTokens;

  final int reasoningTokens;

  bool get isEmpty =>
      inputTokens == 0 &&
      outputTokens == 0 &&
      cacheReadTokens == 0 &&
      cacheWriteTokens == 0 &&
      reasoningTokens == 0;
}

class ChatSession {
  const ChatSession({
    required this.id,
    required this.title,
    required this.group,
    required this.time,
    required this.preview,
    required this.model,
    required this.files,
    required this.messages,
  });

  /// 稳定 ID，同时是工作区目录名（见功能协议 §2.1）。
  final String id;

  /// 仅用于界面显示，默认取用户第一句话的前几个字。
  final String title;

  /// 会话列表分组，例如「今天」。
  final String group;

  final String time;
  final String preview;
  final String model;
  final List<WorkspaceFile> files;
  final List<ChatMessage> messages;

  ChatSession copyWith({
    String? title,
    String? preview,
    String? time,
    String? model,
    List<WorkspaceFile>? files,
    List<ChatMessage>? messages,
  }) {
    return ChatSession(
      id: id,
      title: title ?? this.title,
      group: group,
      time: time ?? this.time,
      preview: preview ?? this.preview,
      model: model ?? this.model,
      files: files ?? this.files,
      messages: messages ?? this.messages,
    );
  }
}
