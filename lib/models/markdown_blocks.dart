/// Markdown 文本 → 内容块（实施 TODO M1）。
///
/// 只解析**块级**结构：标题、代码块、列表、引用、表格、段落。行内样式
/// （`**粗体**`、`` `代码` ``）由 `inline_text.dart` 渲染时处理，这里不拆。
///
/// 设计决策：
/// - **未闭合的代码块当作已闭合**：流式生成时最后一块必然是未闭合的，
///   显示成字面 ` ```lang ` 而非代码块会让用户以为坏了。
/// - 不支持嵌套：列表项里的子列表、引用里的代码块都当纯文本。
/// - 表格必须有表头行；没有分隔行的当普通文本。
library;

import 'content.dart';

/// 解析 Markdown 文本为块列表。
List<ContentBlock> parseMarkdownBlocks(String text) {
  if (text.trim().isEmpty) return const <ContentBlock>[];

  final List<ContentBlock> blocks = <ContentBlock>[];
  final List<String> lines = text.split('\n');
  int i = 0;

  while (i < lines.length) {
    final String line = lines[i];

    // 空行跳过。
    if (line.trim().isEmpty) {
      i++;
      continue;
    }

    // 代码块：``` 开头，收集到下一个 ``` 或文本结束。
    if (line.trimLeft().startsWith('```')) {
      final _CodeFence fence = _parseCodeFence(lines, i);
      blocks.add(CodeBlock(fence.lang, fence.code));
      i = fence.endIndex;
      continue;
    }

    // 块级公式：$$ 开头。和代码围栏一样收集到闭合处，未闭合当已闭合
    // ——流式生成时最后一块必然未闭合。
    if (line.trim().startsWith(r'$$')) {
      final _MathFence fence = _parseMathFence(lines, i);
      // 只有 $$ 没有内容时不产生空块（流式刚吐出定界符的那一帧）。
      if (fence.latex.trim().isNotEmpty) blocks.add(MathBlock(fence.latex));
      i = fence.endIndex;
      continue;
    }

    // 标题：# 开头。
    final int hashes = _headingHashes(line);
    if (hashes > 0) {
      blocks.add(
        HeadingBlock(
          line.trimLeft().substring(hashes).trim(),
          // 规范化到 1~3：界面只有三档字号。
          level: hashes <= 3 ? hashes : 3,
        ),
      );
      i++;
      continue;
    }

    // 引用：> 开头，连续多行合并。
    if (line.trimLeft().startsWith('>')) {
      final _TextRun run = _collectQuote(lines, i);
      blocks.add(QuoteBlock(run.text));
      i = run.endIndex;
      continue;
    }

    // 无序列表：- 或 * 开头。
    if (_isUnorderedListItem(line)) {
      final _ListRun run = _collectList(lines, i, ordered: false);
      blocks.add(BulletListBlock(run.items, ordered: false));
      i = run.endIndex;
      continue;
    }

    // 有序列表：数字. 开头。
    if (_isOrderedListItem(line)) {
      final _ListRun run = _collectList(lines, i, ordered: true);
      blocks.add(BulletListBlock(run.items, ordered: true));
      i = run.endIndex;
      continue;
    }

    // 表格：`|` 开头且下一行是分隔行。没有分隔行的一串竖线不是表格，
    // 落到下面的段落分支。
    if (_startsTable(lines, i)) {
      final _TableRun? table = _parseTable(lines, i);
      if (table != null) {
        blocks.add(TableBlock(table.head, table.rows));
        i = table.endIndex;
        continue;
      }
    }

    // 图片独占一行（![alt](url)）。整段只有这一张图才成块，图片混在
    // 文字里时按普通文本渲染——行内图片与文字的混排是另一件事。
    if (_isImageLine(line) && _isImageOnlyParagraph(lines, i)) {
      final _ImageRun? image = _parseImageLine(line);
      if (image != null) {
        blocks.add(ImageBlock(image.src, alt: image.alt));
        i++;
        continue;
      }
    }

    // 默认：段落。连续多行合并（直到空行 / 特殊块开始）。
    final _TextRun run = _collectParagraph(lines, i);
    blocks.add(ParagraphBlock(run.text));
    i = run.endIndex;
  }

  return blocks;
}

// ────────────────── 代码块 ──────────────────

class _CodeFence {
  const _CodeFence(this.lang, this.code, this.endIndex);

  final String lang;
  final String code;
  final int endIndex;
}

_CodeFence _parseCodeFence(List<String> lines, int start) {
  final String firstLine = lines[start].trimLeft();
  final String lang = firstLine.substring(3).trim();
  final List<String> codeLines = <String>[];
  int i = start + 1;

  while (i < lines.length) {
    final String line = lines[i];
    if (line.trimLeft().startsWith('```')) {
      return _CodeFence(lang, codeLines.join('\n'), i + 1);
    }
    codeLines.add(line);
    i++;
  }

  // 未闭合：当作已闭合（流式生成时最后一块必然未闭合）。
  return _CodeFence(lang, codeLines.join('\n'), i);
}

// ────────────────── 块级公式 ──────────────────

class _MathFence {
  const _MathFence(this.latex, this.endIndex);

  final String latex;
  final int endIndex;
}

/// 收集 `$$` 公式块。支持两种形态：
/// - `$$x^2$$` —— 定界符和内容在同一行；
/// - 独立的 `$$` 行打开，后续行是内容，直到 `$$` 行或文本结束。
_MathFence _parseMathFence(List<String> lines, int start) {
  final String first = lines[start].trim();

  // 同行闭合：$$ 内容 $$。
  if (first.length > 4 && first.endsWith(r'$$')) {
    return _MathFence(first.substring(2, first.length - 2), start + 1);
  }

  // 独立的打开行。
  final List<String> body = <String>[];
  int i = start + 1;
  while (i < lines.length) {
    final String line = lines[i].trim();
    if (line.startsWith(r'$$')) {
      return _MathFence(body.join('\n'), i + 1);
    }
    body.add(lines[i]);
    i++;
  }

  // 未闭合：当作已闭合（流式生成时最后一块必然未闭合）。
  return _MathFence(body.join('\n'), i);
}

// ────────────────── 标题 ──────────────────

/// 行首连续的 `#` 个数，不是标题时返回 0。
///
/// 返回的是**原始个数**而不是渲染层级：调用方要用它切掉前缀，clamp 过的
/// 数字切出来会多留一个 `#`。
int _headingHashes(String line) {
  final String trimmed = line.trimLeft();
  int count = 0;
  while (count < trimmed.length && trimmed[count] == '#') {
    count++;
  }
  if (count == 0 || count > 6) return 0;
  // `#hashtag` 不是标题：后面必须有空格。
  if (count >= trimmed.length || trimmed[count] != ' ') return 0;
  return count;
}

// ────────────────── 引用 ──────────────────

class _TextRun {
  const _TextRun(this.text, this.endIndex);

  final String text;
  final int endIndex;
}

_TextRun _collectQuote(List<String> lines, int start) {
  final List<String> texts = <String>[];
  int i = start;

  while (i < lines.length) {
    final String line = lines[i].trimLeft();
    if (!line.startsWith('>')) break;
    texts.add(line.substring(1).trim());
    i++;
  }

  return _TextRun(texts.join('\n'), i);
}

// ────────────────── 列表 ──────────────────

class _ListRun {
  const _ListRun(this.items, this.endIndex);

  final List<String> items;
  final int endIndex;
}

bool _isUnorderedListItem(String line) {
  final String trimmed = line.trimLeft();
  if (trimmed.isEmpty) return false;
  final String first = trimmed[0];
  return (first == '-' || first == '*') &&
      trimmed.length > 1 &&
      trimmed[1] == ' ';
}

bool _isOrderedListItem(String line) {
  final String trimmed = line.trimLeft();
  final RegExp pattern = RegExp(r'^\d+\.\s');
  return pattern.hasMatch(trimmed);
}

_ListRun _collectList(List<String> lines, int start, {required bool ordered}) {
  final List<String> items = <String>[];
  int i = start;

  while (i < lines.length) {
    final String line = lines[i];
    final bool match = ordered
        ? _isOrderedListItem(line)
        : _isUnorderedListItem(line);
    if (!match) break;

    final String trimmed = line.trimLeft();
    final int prefixEnd = ordered ? trimmed.indexOf(RegExp(r'\.\s')) + 2 : 2;
    items.add(trimmed.substring(prefixEnd).trim());
    i++;
  }

  return _ListRun(items, i);
}

// ────────────────── 表格 ──────────────────

class _TableRun {
  const _TableRun(this.head, this.rows, this.endIndex);

  final List<String> head;
  final List<TableRowData> rows;
  final int endIndex;
}

_TableRun? _parseTable(List<String> lines, int start) {
  if (start + 1 >= lines.length) return null;

  final List<String> headCells = _parseTableRow(lines[start]);
  if (headCells.isEmpty) return null;

  final String separator = lines[start + 1];
  if (!_isTableSeparator(separator)) return null;

  final List<TableRowData> rows = <TableRowData>[];
  int i = start + 2;

  while (i < lines.length) {
    final String line = lines[i];
    if (!line.trimLeft().startsWith('|')) break;
    final List<String> cells = _parseTableRow(line);
    if (cells.isEmpty) break;
    rows.add(TableRowData(cells));
    i++;
  }

  return _TableRun(headCells, rows, i);
}

List<String> _parseTableRow(String line) {
  final String trimmed = line.trim();
  if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) {
    return const <String>[];
  }
  // 流式生成时可能只有一个 `|`，length - 1 会是 0，substring(1, 0) 就炸了。
  if (trimmed.length < 2) return const <String>[];
  final String inner = trimmed.substring(1, trimmed.length - 1);
  return inner.split('|').map((String s) => s.trim()).toList();
}

bool _isTableSeparator(String line) {
  final String trimmed = line.trim();
  if (!trimmed.startsWith('|') || !trimmed.endsWith('|')) return false;
  // 流式生成时可能只有一个 `|`。
  if (trimmed.length < 2) return false;
  final String inner = trimmed.substring(1, trimmed.length - 1);
  final List<String> parts = inner.split('|');
  for (final String part in parts) {
    final String p = part.trim();
    if (p.isEmpty) return false;
    if (!RegExp(r'^:?-+:?$').hasMatch(p)) return false;
  }
  return true;
}

// ────────────────── 图片 ──────────────────

class _ImageRun {
  const _ImageRun(this.src, this.alt);

  final String src;
  final String? alt;
}

bool _isImageLine(String line) {
  final String trimmed = line.trim();
  return trimmed.startsWith('![') &&
      trimmed.indexOf('](') > 0 &&
      trimmed.endsWith(')');
}

/// 这一段（从 [start] 收集）是否是"只有一张图"的段落。
///
/// 只看下一行：段落收集是连续的，下一行如果还是正文，这张图就混在文字
/// 里，交回段落分支渲染。
bool _isImageOnlyParagraph(List<String> lines, int start) {
  final int next = start + 1;
  if (next >= lines.length) return true;
  final String line = lines[next];
  return line.trim().isEmpty ||
      line.trimLeft().startsWith('```') ||
      line.trim().startsWith(r'$$') ||
      _headingHashes(line) > 0 ||
      line.trimLeft().startsWith('>') ||
      _isUnorderedListItem(line) ||
      _isOrderedListItem(line) ||
      _startsTable(lines, next);
}

_ImageRun? _parseImageLine(String line) {
  final String trimmed = line.trim();
  final int open = trimmed.indexOf('](');
  if (open < 0) return null;
  final String alt = trimmed.substring(2, open);
  final String src = trimmed.substring(open + 2, trimmed.length - 1).trim();
  if (src.isEmpty) return null;
  return _ImageRun(src, alt);
}

// ────────────────── 段落 ──────────────────

/// 这一行是不是一个表格的开头（有表头也有分隔行）。
///
/// 段落收集要用它而不是"以 `|` 开头"：一串竖线但没有分隔行的行不是表格，
/// 按"是表格"断开会把用户写的一段话拆成好几个段落。
bool _startsTable(List<String> lines, int index) {
  if (!lines[index].trimLeft().startsWith('|')) return false;
  if (index + 1 >= lines.length) return false;
  return _isTableSeparator(lines[index + 1]);
}

_TextRun _collectParagraph(List<String> lines, int start) {
  final List<String> texts = <String>[lines[start]];
  int i = start + 1;

  while (i < lines.length) {
    final String line = lines[i];
    // 空行或下一个块的开始：段落结束。$$ 也要断——段落吃掉打开行，
    // 公式块就永远等不到闭合了。
    if (line.trim().isEmpty ||
        line.trimLeft().startsWith('```') ||
        line.trim().startsWith(r'$$') ||
        _headingHashes(line) > 0 ||
        line.trimLeft().startsWith('>') ||
        _isUnorderedListItem(line) ||
        _isOrderedListItem(line) ||
        _startsTable(lines, i)) {
      break;
    }
    texts.add(line);
    i++;
  }

  return _TextRun(texts.join('\n'), i);
}
