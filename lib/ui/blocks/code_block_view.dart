import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/content.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/toast.dart';

/// 代码块。带语言标签、行数、复制按钮，超宽横向滚动。
class CodeBlockView extends StatelessWidget {
  const CodeBlockView({super.key, required this.block});

  final CodeBlock block;

  /// 只做最小限度的着色：字符串、注释、常见关键字。
  /// 目的是可读，不是完整语法分析。
  static final RegExp _tokens = RegExp(
    r'''("[^"\n]*"|'[^'\n]*'|//[^\n]*|#[^\n]*'''
    r'''|\b(?:const|let|var|function|return|await|async|for|of|in|if|else'''
    r'''|import|from|export|class|def|new|true|false|null|None|with|as)\b)''',
  );

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final String code = block.code.trim();
    final int lines = code.split('\n').length;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Container(
              height: 32,
              padding: const EdgeInsets.only(left: 12, right: 4),
              color: palette.bgRaise.withValues(alpha: 0.7),
              child: Row(
                children: <Widget>[
                  Text(
                    block.lang,
                    style: TextStyle(
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      color: palette.text3,
                    ),
                  ),
                  if (block.title != null) ...<Widget>[
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        block.title!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppFonts.mono(size: 11, color: palette.text2),
                      ),
                    ),
                  ],
                  const Spacer(),
                  Text(
                    '$lines 行',
                    style: TextStyle(fontSize: 10.5, color: palette.text3),
                  ),
                  IconAction(
                    icon: Icons.content_copy_outlined,
                    tooltip: '复制代码',
                    size: 14,
                    box: 28,
                    onTap: () => _copy(context, code),
                  ),
                ],
              ),
            ),
            Container(
              width: double.infinity,
              color: palette.codeBg,
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text.rich(
                  TextSpan(children: _spans(code, palette)),
                  style: AppFonts.mono(
                    size: 12,
                    color: palette.text1,
                    height: 1.6,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<InlineSpan> _spans(String code, AppPalette palette) {
    final List<InlineSpan> spans = <InlineSpan>[];
    int cursor = 0;
    for (final RegExpMatch match in _tokens.allMatches(code)) {
      if (match.start > cursor) {
        spans.add(TextSpan(text: code.substring(cursor, match.start)));
      }
      final String token = match.group(0)!;
      final bool isString = token.startsWith('"') || token.startsWith("'");
      final bool isComment = token.startsWith('//') || token.startsWith('#');
      spans.add(
        TextSpan(
          text: token,
          style: TextStyle(
            color: isString
                ? palette.codeString
                : isComment
                ? palette.text3
                : palette.codeKeyword,
            fontStyle: isComment ? FontStyle.italic : null,
          ),
        ),
      );
      cursor = match.end;
    }
    if (cursor < code.length) {
      spans.add(TextSpan(text: code.substring(cursor)));
    }
    return spans;
  }

  Future<void> _copy(BuildContext context, String code) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    showAppToast(context, '代码已复制');
  }
}
