import 'package:flutter/material.dart';

import '../../models/content.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';

/// 表格块。列宽按内容自适应，超宽时横向滚动（AGENTS 要求宽内容可滚动）。
class TableBlockView extends StatelessWidget {
  const TableBlockView({super.key, required this.block});

  final TableBlock block;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final int columnCount = <int>[
      1,
      block.head.length,
      ...block.rows.map((TableRowData r) => r.cells.length),
    ].reduce((int a, int b) => a > b ? a : b);
    final List<String> head = _fitCells(block.head, columnCount);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(10),
        ),
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Table(
            defaultColumnWidth: const IntrinsicColumnWidth(),
            border: TableBorder(
              horizontalInside: BorderSide(color: palette.border),
            ),
            children: <TableRow>[
              TableRow(
                decoration: BoxDecoration(
                  color: palette.bgRaise.withValues(alpha: 0.6),
                ),
                children: <Widget>[
                  for (int i = 0; i < head.length; i++)
                    _Cell(
                      text: head[i],
                      align: i == 0 ? TextAlign.left : TextAlign.right,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        color: palette.text2,
                      ),
                    ),
                ],
              ),
              for (final TableRowData row in block.rows)
                TableRow(
                  children: <Widget>[
                    for (int i = 0; i < columnCount; i++)
                      _Cell(
                        text: i < row.cells.length ? row.cells[i] : '',
                        align: i == 0 ? TextAlign.left : TextAlign.right,
                        style: i == 0
                            ? TextStyle(fontSize: 12.5, color: palette.text1)
                            : AppFonts.mono(
                                size: 12,
                                color: row.neg ? palette.danger : palette.text1,
                              ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

List<String> _fitCells(List<String> cells, int count) {
  if (cells.length >= count) return cells.take(count).toList();
  return <String>[...cells, ...List<String>.filled(count - cells.length, '')];
}

class _Cell extends StatelessWidget {
  const _Cell({required this.text, required this.align, required this.style});

  final String text;
  final TextAlign align;
  final TextStyle style;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      child: Text(text, textAlign: align, style: style),
    );
  }
}
