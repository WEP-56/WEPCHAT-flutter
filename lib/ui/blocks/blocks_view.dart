import 'package:flutter/material.dart';

import '../../models/content.dart';
import '../../theme/palette.dart';
import 'code_block_view.dart';
import 'inline_text.dart';
import 'table_block_view.dart';

/// 内容块列表渲染入口。聊天正文和文件预览共用。
class BlocksView extends StatelessWidget {
  const BlocksView({super.key, required this.blocks, this.gap = 10});

  final List<ContentBlock> blocks;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final List<Widget> children = <Widget>[];
    for (int i = 0; i < blocks.length; i++) {
      if (i > 0) children.add(SizedBox(height: gap));
      children.add(BlockView(block: blocks[i]));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: children,
    );
  }
}

/// 单个内容块。
class BlockView extends StatelessWidget {
  const BlockView({super.key, required this.block});

  final ContentBlock block;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return switch (block) {
      HeadingBlock(:final String text, :final int level) => Padding(
        padding: EdgeInsets.only(top: level == 1 ? 0 : 4, bottom: 2),
        child: InlineText(
          text,
          size: switch (level) {
            1 => 17,
            2 => 15,
            _ => 13.5,
          },
          height: 1.35,
          weight: FontWeight.w700,
        ),
      ),
      ParagraphBlock(:final String text) => InlineText(text),
      BulletListBlock(:final List<String> items, :final bool ordered) =>
        _ListView(items: items, ordered: ordered),
      QuoteBlock(:final String text) => Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        decoration: BoxDecoration(
          color: palette.bgPanel,
          border: Border(left: BorderSide(color: palette.accent, width: 3)),
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(8),
          ),
        ),
        child: InlineText(text, size: 13, color: palette.text2),
      ),
      final TableBlock block => TableBlockView(block: block),
      final CodeBlock block => CodeBlockView(block: block),
    };
  }
}

class _ListView extends StatelessWidget {
  const _ListView({required this.items, required this.ordered});

  final List<String> items;
  final bool ordered;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (int i = 0; i < items.length; i++)
          Padding(
            padding: EdgeInsets.only(bottom: i == items.length - 1 ? 0 : 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  width: 20,
                  child: ordered
                      ? Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            '${i + 1}.',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: palette.text3,
                            ),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.only(top: 8, left: 5),
                          child: Container(
                            width: 4,
                            height: 4,
                            decoration: BoxDecoration(
                              color: palette.text3,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                ),
                Expanded(child: InlineText(items[i], height: 1.55)),
              ],
            ),
          ),
      ],
    );
  }
}
