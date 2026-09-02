/// 富文本内容块。
///
/// 聊天消息正文和工作区文件预览共用同一套块模型，避免两处各写一套渲染逻辑。
sealed class ContentBlock {
  const ContentBlock();
}

class HeadingBlock extends ContentBlock {
  const HeadingBlock(this.text, {this.level = 2});

  final String text;

  /// 1 ~ 3，对应渲染字号。
  final int level;
}

class ParagraphBlock extends ContentBlock {
  const ParagraphBlock(this.text);

  /// 支持 `**粗体**`、`` `行内代码` `` 和 `[1]` 引用角标。
  final String text;
}

class BulletListBlock extends ContentBlock {
  const BulletListBlock(this.items, {this.ordered = false});

  final List<String> items;
  final bool ordered;
}

class QuoteBlock extends ContentBlock {
  const QuoteBlock(this.text);

  final String text;
}

class TableBlock extends ContentBlock {
  const TableBlock(this.head, this.rows);

  final List<String> head;
  final List<TableRowData> rows;
}

class CodeBlock extends ContentBlock {
  const CodeBlock(this.lang, this.code, {this.title});

  final String lang;
  final String code;
  final String? title;
}

/// 块级数学公式（`$$...$$`）。
///
/// 单独成块而不是塞进段落：块级公式在排版上要居中、独占一行，而段落里的
/// 行内公式（`$...$`）由 `InlineText` 处理，两者的布局要求不一样。
class MathBlock extends ContentBlock {
  const MathBlock(this.latex);

  /// 去掉 `$$` 定界符之后的 LaTeX 源码。
  final String latex;
}

/// 图片（`![alt](url)` 独占一行时）。
///
/// 图片本身是行内语法，但一整行只有一张图时单独成块，可以独占宽度、
/// 圆角裁切；混在文字里的图片第一版不强求，按普通文本渲染。链接的图片
/// （http 开头）直接加载；工作区路径（非 http）走本地文件。
class ImageBlock extends ContentBlock {
  const ImageBlock(this.src, {this.alt});

  final String src;
  final String? alt;
}

/// 表格行。[neg] 表示该行数值为负，渲染成告警色。
class TableRowData {
  const TableRowData(this.cells, {this.neg = false});

  final List<String> cells;
  final bool neg;
}
