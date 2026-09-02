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
    this.attachments = const <Attachment>[],
    this.tools = const <ToolCall>[],
    this.blocks = const <ContentBlock>[],
    this.images = const <ImageResult>[],
    this.files = const <String>[],
    this.html,
    this.isStreaming = false,
  });

  final String id;
  final ChatRole role;

  bool get isUser => role == ChatRole.user;

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

  ChatMessage copyWith({
    List<ToolCall>? tools,
    List<ContentBlock>? blocks,
    List<ImageResult>? images,
    List<String>? files,
    HtmlRef? html,
    bool? isStreaming,
  }) {
    return ChatMessage(
      id: id,
      role: role,
      time: time,
      attachments: attachments,
      tools: tools ?? this.tools,
      blocks: blocks ?? this.blocks,
      images: images ?? this.images,
      files: files ?? this.files,
      html: html ?? this.html,
      isStreaming: isStreaming ?? this.isStreaming,
    );
  }
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
