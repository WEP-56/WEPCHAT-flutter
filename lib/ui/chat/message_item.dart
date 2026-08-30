import 'package:flutter/material.dart';

import '../../models/chat.dart';
import '../../models/tool_call.dart';
import '../../theme/palette.dart';
import '../blocks/blocks_view.dart';
import '../widgets/file_visuals.dart';
import 'artifact_cards.dart';
import 'tool_row.dart';
import 'typing_dots.dart';

/// 单条消息。用户消息是右侧气泡，助手消息是左侧全宽内容流。
class MessageItemView extends StatelessWidget {
  const MessageItemView({
    super.key,
    required this.message,
    required this.gallery,
  });

  final ChatMessage message;

  /// 当前会话的图片列表，供图片查看器切换。
  final List<String> gallery;

  @override
  Widget build(BuildContext context) {
    return message.isUser ? _buildUser(context) : _buildAssistant(context);
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
    return Container(
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
    );
  }
}
