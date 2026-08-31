import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../mock/file_bodies.dart';
import '../../models/content.dart';
import '../../models/workspace.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../blocks/blocks_view.dart';
import '../blocks/code_block_view.dart';
import '../blocks/table_block_view.dart';
import '../widgets/controls.dart';
import '../widgets/file_visuals.dart';
import '../widgets/toast.dart';

/// 工作区文件预览页。
class FileViewerScreen extends StatelessWidget {
  const FileViewerScreen({super.key, required this.file});

  /// 工作区相对路径。
  final String file;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final FileKind kind = fileKindFromName(file);

    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        toolbarHeight: 50,
        titleSpacing: 4,
        backgroundColor: palette.bgSide,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Row(
          children: <Widget>[
            FileIconBox(kind: kind, size: 24, radius: 6),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                file,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.mono(size: 12.5, color: palette.text1),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          IconAction(
            icon: Icons.download_outlined,
            tooltip: '导出',
            onTap: () => showAppToast(context, '导出文件（预览版未接入文件系统）'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 820),
              child: SizedBox(
                width: double.infinity,
                child: _buildContent(context, kind),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildContent(BuildContext context, FileKind kind) {
    if (kind == FileKind.png || kind == FileKind.jpg) {
      return WorkspaceImage(file: file);
    }

    final FileBody? body = kFileBodies[file];
    if (body == null) {
      return _Notice(
        icon: Icons.help_outline,
        text: '该文件没有内置预览内容。纯前端阶段只为部分示例文件准备了 mock 内容。',
      );
    }

    return switch (body) {
      BlocksFileBody(:final List<ContentBlock> blocks) => BlocksView(
        blocks: blocks,
        gap: 12,
      ),
      CodeFileBody(:final String lang, :final String code) => CodeBlockView(
        block: CodeBlock(lang, code, title: file),
      ),
      CsvFileBody(:final List<String> head, :final List<List<String>> rows) =>
        TableBlockView(
          block: TableBlock(
            head,
            rows.map((List<String> cells) => TableRowData(cells)).toList(),
          ),
        ),
      HtmlFileBody() => _HtmlEntry(file: file),
      BinaryFileBody(:final String note) => _Notice(
        icon: Icons.picture_as_pdf_outlined,
        text: note,
      ),
    };
  }
}

class _HtmlEntry extends StatelessWidget {
  const _HtmlEntry({required this.file});

  final String file;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bgPanel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.language, size: 18, color: palette.accent),
              const SizedBox(width: 8),
              Text(
                'HTML 页面',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: palette.text1,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '页面内容需要在沙盒里渲染，点击下面的按钮进入预览。',
            style: TextStyle(fontSize: 12, color: palette.text3),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => AppNav.openHtml(context, file: file),
            icon: const Icon(Icons.play_arrow, size: 16),
            label: const Text('打开预览'),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: palette.bgPanel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: palette.text3),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
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
