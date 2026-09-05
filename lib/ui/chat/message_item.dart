import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'dart:convert';

import '../../models/chat.dart';
import '../../models/tool_call.dart';
import '../../theme/palette.dart';
import '../blocks/blocks_view.dart';
import '../widgets/file_visuals.dart';
import 'artifact_cards.dart';
import 'message_action_bar.dart';
import 'tool_row.dart';
import 'typing_dots.dart';

/// 单条消息。用户消息是右侧气泡，助手消息是左侧全宽内容流。
class MessageItemView extends StatefulWidget {
  const MessageItemView({
    super.key,
    required this.message,
    required this.gallery,
    this.onRegenerate,
    this.onEdit,
  });

  final ChatMessage message;

  /// 当前会话的图片列表，供图片查看器切换。
  final List<String> gallery;

  /// 重发 / 编辑重发。为 null 时对应按钮不出现——生成中、流式草稿、
  /// 助手消息的「编辑」都是这种情况。
  final VoidCallback? onRegenerate;
  final VoidCallback? onEdit;

  @override
  State<MessageItemView> createState() => _MessageItemViewState();
}

class _MessageItemViewState extends State<MessageItemView> {
  /// 鼠标停在这条消息上。操作栏平时透明：每条消息底下常驻一行按钮会把
  /// 对话切得很碎，而悬停范围取整条消息（不只是那一行）才找得到。
  bool _hovered = false;

  ChatMessage get message => widget.message;
  List<String> get gallery => widget.gallery;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
      onExit: (PointerExitEvent _) => setState(() => _hovered = false),
      child: message.isUser ? _buildUser(context) : _buildAssistant(context),
    );
  }

  /// 消息底部的用量与操作。
  ///
  /// 流式草稿不挂（在 `_buildAssistant` 里挡掉）：它还没落库，`seq` 是 0，
  /// 撤回没有落点，复制也只能复制到半句话。
  Widget _actionBar({required bool alignEnd}) {
    return MessageActionBar(
      message: message,
      alignEnd: alignEnd,
      hovered: _hovered,
      onRegenerate: widget.onRegenerate,
      onEdit: widget.onEdit,
    );
  }

  Widget _buildUser(BuildContext context) {
    final AppPalette palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        if (message.attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 6,
              runSpacing: 6,
              children: message.attachments
                  .map((Attachment a) => _AttachmentChip(attachment: a))
                  .toList(),
            ),
          ),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: palette.accent,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(18),
                topRight: Radius.circular(18),
                bottomLeft: Radius.circular(18),
                bottomRight: Radius.circular(6),
              ),
            ),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: Colors.white),
              child: BlocksView(blocks: message.blocks, gap: 8),
            ),
          ),
        ),
        _actionBar(alignEnd: true),
      ],
    );
  }

  Widget _buildAssistant(BuildContext context) {
    final List<Widget> children = <Widget>[];

    for (final ToolCall call in message.tools) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: ToolRowView(call: call),
        ),
      );
      for (final String file in call.outputFiles) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: ImageResultView(
              result: ImageResult(file: file, meta: call.title),
              gallery: gallery,
            ),
          ),
        );
      }
      final String? htmlFile = call.htmlFile;
      if (htmlFile != null) {
        children.add(
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: HtmlArtifactCard(
              ref: HtmlRef(
                file: htmlFile,
                title: htmlFile.split('/').last,
                desc: 'HTML 预览',
              ),
            ),
          ),
        );
      }
    }
    if (message.blocks.isNotEmpty) {
      children.add(BlocksView(blocks: message.blocks));
    }
    if (message.isStreaming) {
      children.add(
        const Padding(padding: EdgeInsets.only(top: 2), child: TypingDots()),
      );
    }
    for (final ImageResult image in message.images) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: ImageResultView(result: image, gallery: gallery),
        ),
      );
    }
    if (message.html != null) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: HtmlArtifactCard(ref: message.html!),
        ),
      );
    }
    if (message.files.isNotEmpty) {
      children.add(
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: message.files
                .map((String file) => FileChip(file: file))
                .toList(),
          ),
        ),
      );
    }
    // 只有工具卡片的那条不带操作栏：它不是模型说的话，没有可复制的正文，
    // 也没有自己的 `seq` 可撤回（见 `SessionStore._toolOnlyMessage`）。
    if (message.role == ChatRole.assistant &&
        !message.isStreaming &&
        message.rawText.trim().isNotEmpty) {
      children.add(_actionBar(alignEnd: false));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  const _AttachmentChip({required this.attachment});

  final Attachment attachment;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool image =
        attachment.mimeType?.startsWith('image/') == true &&
        attachment.base64Data != null;
    return GestureDetector(
      onTap: attachment.base64Data == null
          ? null
          : () => showDialog<void>(
              context: context,
              builder: (_) {
                if (image)
                  return Dialog(
                    child: InteractiveViewer(
                      child: Image.memory(base64Decode(attachment.base64Data!)),
                    ),
                  );
                final String text = utf8.decode(
                  base64Decode(attachment.base64Data!),
                  allowMalformed: true,
                );
                return AlertDialog(
                  title: Text(attachment.name),
                  content: SingleChildScrollView(child: SelectableText(text)),
                );
              },
            ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: palette.bgPanel,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FileIconBox(kind: attachment.kind, size: 20, radius: 5),
            const SizedBox(width: 7),
            Text(
              attachment.name,
              style: TextStyle(fontSize: 11.5, color: palette.text1),
            ),
            const SizedBox(width: 6),
            Text(
              attachment.size,
              style: TextStyle(fontSize: 10.5, color: palette.text3),
            ),
          ],
        ),
      ),
    );
  }
}
