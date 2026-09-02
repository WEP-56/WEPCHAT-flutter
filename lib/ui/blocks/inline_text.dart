import 'package:flutter/material.dart';

import '../../theme/fonts.dart';
import '../../theme/palette.dart';

/// 行内轻量 Markdown：`**粗体**`、`` `行内代码` ``、`[1]` 引用角标。
///
/// 只管**行内**：块级结构（标题、围栏代码、列表、表格）在进渲染层之前就已经
/// 被 `parseMarkdownBlocks` 拆成了 [ContentBlock]，到这里的每段文本都是一个
/// 块的内容，不会再有 ``` 或行首的 `#`。
class InlineText extends StatelessWidget {
  const InlineText(
    this.text, {
    super.key,
    this.size = 13.5,
    this.color,
    this.height = 1.65,
    this.weight,
  });

  final String text;
  final double size;
  final Color? color;
  final double height;
  final FontWeight? weight;

  static final RegExp _pattern = RegExp(r'(\*\*[^*]+\*\*|`[^`]+`|\[\d+\])');

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final TextStyle base = TextStyle(
      fontSize: size,
      height: height,
      color: color ?? palette.text1,
      fontWeight: weight,
    );

    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    for (final RegExpMatch match in _pattern.allMatches(text)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: text.substring(cursor, match.start)));
      }
      spans.add(_spanFor(match.group(0)!, base, palette));
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(TextSpan(style: base, children: spans));
  }

  InlineSpan _spanFor(String token, TextStyle base, AppPalette palette) {
    if (token.startsWith('**')) {
      return TextSpan(
        text: token.substring(2, token.length - 2),
        style: const TextStyle(fontWeight: FontWeight.w700),
      );
    }
    if (token.startsWith('`')) {
      return TextSpan(
        text: token.substring(1, token.length - 1),
        style: AppFonts.mono(
          size: size - 1,
          color: palette.text1,
        ).copyWith(backgroundColor: palette.bgRaise),
      );
    }
    return WidgetSpan(
      alignment: PlaceholderAlignment.top,
      child: Padding(
        padding: const EdgeInsets.only(left: 1, right: 1),
        child: Text(
          token.substring(1, token.length - 1),
          style: TextStyle(
            fontSize: size - 4.5,
            fontWeight: FontWeight.w700,
            color: palette.accent,
          ),
        ),
      ),
    );
  }
}
