import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../models/content.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/file_visuals.dart';
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
      ThinkingBlock(:final String text) => _ThinkingBlockView(text: text),
      final TableBlock block => TableBlockView(block: block),
      final CodeBlock block => CodeBlockView(block: block),
      MathBlock(:final String latex) => _MathBlockView(latex: latex),
      ImageBlock(:final String src, :final String? alt) => _ImageBlockView(
        src: src,
        alt: alt,
      ),
    };
  }
}

class _ThinkingBlockView extends StatefulWidget {
  const _ThinkingBlockView({required this.text});

  final String text;

  @override
  State<_ThinkingBlockView> createState() => _ThinkingBlockViewState();
}

class _ThinkingBlockViewState extends State<_ThinkingBlockView> {
  bool _expanded = true;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      decoration: BoxDecoration(
        color: palette.bgPanel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () => setState(() => _expanded = !_expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.psychology_outlined, size: 16, color: palette.accent),
                  const SizedBox(width: 7),
                  Text(
                    '思考过程',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: palette.text2,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    _expanded ? '收起' : '展开',
                    style: TextStyle(fontSize: 11, color: palette.text3),
                  ),
                  const SizedBox(width: 3),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    size: 16,
                    color: palette.text3,
                  ),
                ],
              ),
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
              child: InlineText(widget.text, size: 13, color: palette.text2),
            ),
          if (_expanded)
            Align(
              alignment: Alignment.centerRight,
              child: InkWell(
                onTap: () => setState(() => _expanded = false),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 6),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        '收起',
                        style: TextStyle(fontSize: 11, color: palette.text3),
                      ),
                      const SizedBox(width: 3),
                      Icon(Icons.expand_less, size: 16, color: palette.text3),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 块级公式：居中、可横向滚动。
///
/// 长公式在窄屏上会超出宽度，套一层横向滚动而不是缩放——缩到看不清
/// 还不如让人划一下。
class _MathBlockView extends StatelessWidget {
  const _MathBlockView({required this.latex});

  final String latex;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return SizedBox(
      width: double.infinity,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Math.tex(
          latex,
          textStyle: TextStyle(fontSize: 15, color: palette.text1),
          // 模型偶尔吐出不合法的 LaTeX，显示源码比显示错误框有用。
          onErrorFallback: (Object _) =>
              Text(latex, style: AppFonts.mono(size: 12, color: palette.text2)),
        ),
      ),
    );
  }
}

/// 独占一行的图片。网络图直接加载，工作区路径读本地文件。
class _ImageBlockView extends StatelessWidget {
  const _ImageBlockView({required this.src, this.alt});

  final String src;
  final String? alt;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool remote = src.startsWith('http://') || src.startsWith('https://');

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxHeight: 360),
        child: remote
            ? Image.network(
                src,
                fit: BoxFit.contain,
                alignment: Alignment.centerLeft,
                loadingBuilder:
                    (
                      BuildContext context,
                      Widget child,
                      ImageChunkEvent? progress,
                    ) {
                      if (progress == null) return child;
                      return _Placeholder(
                        icon: Icons.downloading_outlined,
                        text: alt?.isNotEmpty == true ? alt! : '加载中…',
                        palette: palette,
                      );
                    },
                errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                    _Placeholder(
                      icon: Icons.broken_image_outlined,
                      text: alt?.isNotEmpty == true ? alt! : '图片加载失败',
                      palette: palette,
                    ),
              )
            : WorkspaceImage(file: src),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder({
    required this.icon,
    required this.text,
    required this.palette,
  });

  final IconData icon;
  final String text;
  final AppPalette palette;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 90,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 16, color: palette.text3),
          const SizedBox(width: 8),
          Text(text, style: TextStyle(fontSize: 11.5, color: palette.text3)),
        ],
      ),
    );
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
