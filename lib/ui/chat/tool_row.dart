import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../browser/browser_launcher.dart';
import '../../models/tool_call.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';

IconData toolKindIcon(ToolKind kind) {
  return switch (kind) {
    ToolKind.search => Icons.public,
    ToolKind.fetch => Icons.article_outlined,
    ToolKind.script => Icons.terminal,
    ToolKind.image => Icons.image_outlined,
    ToolKind.file => Icons.note_add_outlined,
    ToolKind.memory => Icons.psychology_alt_outlined,
  };
}

/// 工具调用卡片。折叠时只显示一行摘要，展开后显示参数与来源。
class ToolRowView extends StatefulWidget {
  const ToolRowView({super.key, required this.call});

  final ToolCall call;

  @override
  State<ToolRowView> createState() => _ToolRowViewState();
}

class _ToolRowViewState extends State<ToolRowView> {
  bool _expanded = false;

  bool get _hasDetail {
    final ToolCall call = widget.call;
    return call.detail != null ||
        call.query != null ||
        call.prompt != null ||
        call.meta != null ||
        call.note != null ||
        call.sources.isNotEmpty;
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final ToolCall call = widget.call;

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 560),
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(10),
          color: palette.bgPanel,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            InkWell(
              onTap: _hasDetail
                  ? () => setState(() => _expanded = !_expanded)
                  : null,
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                child: Row(
                  children: <Widget>[
                    SizedBox(
                      width: 16,
                      height: 16,
                      child: call.isRunning
                          ? CircularProgressIndicator(
                              strokeWidth: 1.6,
                              color: palette.accent,
                            )
                          : Icon(
                              toolKindIcon(call.kind),
                              size: 15,
                              color: palette.text2,
                            ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      call.title,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: palette.text1,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        call.found ?? call.detail ?? call.meta ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 11.5, color: palette.text3),
                      ),
                    ),
                    if (call.duration != null)
                      Text(
                        call.duration!,
                        style: TextStyle(fontSize: 10.5, color: palette.text3),
                      ),
                    const SizedBox(width: 6),
                    Icon(
                      call.isRunning
                          ? Icons.more_horiz
                          : (call.status == ToolStatus.failed
                                ? Icons.error_outline
                                : Icons.check),
                      size: 13,
                      color: call.status == ToolStatus.failed
                          ? palette.danger
                          : palette.good,
                    ),
                    if (_hasDetail)
                      Icon(
                        _expanded ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: palette.text3,
                      ),
                  ],
                ),
              ),
            ),
            if (_expanded) _ToolDetail(call: call),
          ],
        ),
      ),
    );
  }
}

class _ToolDetail extends StatelessWidget {
  const _ToolDetail({required this.call});

  final ToolCall call;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final List<Widget> rows = <Widget>[];

    void addMono(String label, String value) {
      rows.add(_labelled(palette, label, value, mono: true));
    }

    if (call.query != null) addMono('query', call.query!);
    if (call.prompt != null) addMono('prompt', call.prompt!);
    if (call.meta != null) addMono('参数', call.meta!);
    if (call.note != null) addMono('记忆', call.note!);
    if (call.detail != null) {
      rows.add(_labelled(palette, '结果', call.detail!));
    }
    if (call.sources.isNotEmpty) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: call.sources
                .map((SourceChip chip) => _SourceChipView(chip: chip))
                .toList(),
          ),
        ),
      );
    }
    if (call.fileChange != null) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _FileDiffCard(change: call.fileChange!),
        ),
      );
    } else if (call.file != null) {
      rows.add(
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: _FileJumpCard(file: call.file!),
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(34, 2, 10, 10),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: rows,
      ),
    );
  }

  Widget _labelled(
    AppPalette palette,
    String label,
    String value, {
    bool mono = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Text(
              label,
              style: TextStyle(fontSize: 10.5, color: palette.text3),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: mono
                  ? AppFonts.mono(size: 11, color: palette.text2, height: 1.5)
                  : TextStyle(
                      fontSize: 11.5,
                      color: palette.text2,
                      height: 1.5,
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SourceChipView extends StatelessWidget {
  const _SourceChipView({required this.chip});

  final SourceChip chip;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return InkWell(
      onTap: chip.url == null ? null : () => openWebUrl(context, chip.url!),
      borderRadius: BorderRadius.circular(6),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: palette.bgRaise,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.link, size: 11, color: palette.accent),
            const SizedBox(width: 5),
            Text(
              chip.name,
              style: TextStyle(fontSize: 11, color: palette.text1),
            ),
            const SizedBox(width: 5),
            Text(
              chip.host,
              style: AppFonts.mono(size: 10, color: palette.text3),
            ),
          ],
        ),
      ),
    );
  }
}

class _FileJumpCard extends StatelessWidget {
  const _FileJumpCard({required this.file});
  final String file;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool html =
        file.toLowerCase().endsWith('.html') ||
        file.toLowerCase().endsWith('.htm');
    return InkWell(
      onTap: () => html
          ? AppNav.openHtml(context, file: file)
          : AppNav.openFile(context, file: file),
      borderRadius: BorderRadius.circular(8),
      child: Ink(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        decoration: BoxDecoration(
          color: palette.bgRaise,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: <Widget>[
            Icon(
              html ? Icons.language : Icons.insert_drive_file_outlined,
              size: 16,
              color: palette.accent,
            ),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                file,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.mono(size: 11, color: palette.text1),
              ),
            ),
            Icon(
              html ? Icons.open_in_browser : Icons.open_in_new,
              size: 14,
              color: palette.text3,
            ),
          ],
        ),
      ),
    );
  }
}

class _FileDiffCard extends StatelessWidget {
  const _FileDiffCard({required this.change});
  final FileChangePreview change;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Ink(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          InkWell(
            onTap: () => AppNav.openFile(context, file: change.path),
            borderRadius: BorderRadius.circular(5),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.difference_outlined,
                    size: 15,
                    color: palette.accent,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '已修改 ${change.path}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: palette.text1),
                    ),
                  ),
                  Text(
                    '${change.replacements} 处',
                    style: TextStyle(fontSize: 10, color: palette.text3),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          _DiffLine(prefix: '-', value: change.before, color: palette.danger),
          const SizedBox(height: 3),
          _DiffLine(prefix: '+', value: change.after, color: palette.good),
        ],
      ),
    );
  }
}

class _DiffLine extends StatelessWidget {
  const _DiffLine({
    required this.prefix,
    required this.value,
    required this.color,
  });
  final String prefix;
  final String value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
      color: color.withValues(alpha: 0.1),
      child: Text(
        '$prefix ${value.replaceAll('\n', ' ↵ ')}',
        maxLines: 3,
        overflow: TextOverflow.ellipsis,
        style: AppFonts.mono(size: 10.5, color: color),
      ),
    );
  }
}
