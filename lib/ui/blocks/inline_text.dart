import 'package:flutter/material.dart';
import 'package:flutter_math_fork/flutter_math.dart';

import '../../browser/browser_launcher.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';

/// 行内轻量 Markdown：`**粗体**`、`` `行内代码` ``、`[1]` 引用角标、
/// `[文字](链接)`、`$公式$`。
///
/// 只管**行内**：块级结构（标题、围栏代码、列表、表格、$$公式$$、图片）
/// 在进渲染层之前就已经被 `parseMarkdownBlocks` 拆成了 [ContentBlock]，
/// 到这里的每段文本都是一个块的内容，不会再有 ``` 或行首的 `#`。
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

  /// 顺序有讲究：`$` 的优先级最低，得放最后（`[1]` 角标与链接共享 `[]`，
  /// 由捕获组区分）。
  static final RegExp _pattern = RegExp(
    r'(\*\*[^*]+\*\*'
    r'|`[^`]+`'
    r'|!?\[[^\]]*\]\([^)\s]+(?:[^)]*)\)'
    r'|\[(\d+)\]'
    r'|\$[^$\s][^$]*?\$)',
  );

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
      spans.add(_spanFor(context, match.group(0)!, match, base, palette));
      cursor = match.end;
    }
    if (cursor < text.length) {
      spans.add(TextSpan(text: text.substring(cursor)));
    }

    return Text.rich(TextSpan(style: base, children: spans));
  }

  InlineSpan _spanFor(
    BuildContext context,
    String token,
    RegExpMatch match,
    TextStyle base,
    AppPalette palette,
  ) {
    // 角标 [1] —— 只有内层数字捕获组才代表引用角标。
    // 外层 group(1) 包住了整个 token，链接/粗体等匹配时同样有值。
    if (match.group(2) != null) {
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

    // 链接 [文字](url) 或图片 ![alt](url)。图片在行内位置渲染成小图。
    if (token.startsWith('[') || token.startsWith('![')) {
      return _linkSpan(context, token, palette);
    }

    // 行内公式 $...$。渲染失败就退回原始文本：模型偶尔会吐出
    // 不合法的 LaTeX，那时显示 `$x^$` 也比一个红色错误框强。
    if (token.startsWith(r'$')) {
      final String latex = token.substring(1, token.length - 1);
      return WidgetSpan(
        alignment: PlaceholderAlignment.middle,
        child: Math.tex(
          latex,
          textStyle: base,
          onErrorFallback: (Object _) => Text(token, style: base),
        ),
      );
    }

    // 兜底：原样文本。
    return TextSpan(text: token);
  }

  InlineSpan _linkSpan(BuildContext context, String token, AppPalette palette) {
    final bool image = token.startsWith('![');
    final int close = token.indexOf('](');
    if (close < 0) return TextSpan(text: token);

    final String label = token.substring(image ? 2 : 1, close);
    final String url = token.substring(close + 2, token.length - 1).trim();

    final Widget child = image
        ? _inlineImage(url, label, palette)
        : Text(
            label,
            style: TextStyle(
              fontSize: size,
              height: height,
              fontWeight: weight,
              color: palette.accent,
              decoration: TextDecoration.underline,
              decorationColor: palette.accent.withValues(alpha: 0.5),
            ),
          );

    return WidgetSpan(
      alignment: PlaceholderAlignment.middle,
      child: MouseRegion(
        cursor: url.isEmpty ? MouseCursor.defer : SystemMouseCursors.click,
        child: GestureDetector(
          onTap: url.isEmpty ? null : () => openWebUrl(context, url),
          child: child,
        ),
      ),
    );
  }

  Widget _inlineImage(String url, String alt, AppPalette palette) {
    if (url.startsWith('http://') || url.startsWith('https://')) {
      return Image.network(
        url,
        width: 20,
        height: 20,
        fit: BoxFit.cover,
        errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
            Icon(Icons.broken_image_outlined, size: 15, color: palette.text3),
      );
    }
    return Tooltip(
      message: alt.isEmpty ? url : alt,
      child: Icon(Icons.image_outlined, size: 15, color: palette.text3),
    );
  }
}
