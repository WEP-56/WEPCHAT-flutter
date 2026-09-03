import 'dart:io';

import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../mock/file_bodies.dart';
import '../../models/content.dart';
import '../../models/workspace.dart';
import '../../platform/workspace_file_service.dart';
import '../../state/app_scope.dart';
import '../../models/markdown_blocks.dart';
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
            onTap: () async {
              final String path = context.sessions.workspacePathFor(
                context.sessions.active.id,
              );
              final bool ok = await WorkspaceFileService(path).export(file);
              if (context.mounted) {
                showAppToast(context, ok ? '已导出 $file' : '导出已取消或失败');
              }
            },
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
      final String path = context.sessions.workspacePathFor(
        context.sessions.active.id,
      );
      return File(pathForRelative(path, file)).existsSync()
          ? Image.file(File(pathForRelative(path, file)), fit: BoxFit.contain)
          : WorkspaceImage(file: file);
    }

    // HTML 文件不依赖 mock 内容表：工作区里实际生成的任意 .html/.htm
    // 都应能直接交给系统默认浏览器打开。
    if (kind == FileKind.html) return _HtmlEntry(file: file);

    final String workspace = context.sessions.workspacePathFor(
      context.sessions.active.id,
    );
    final String absolute = pathForRelative(workspace, file);
    if (File(absolute).existsSync() &&
        <FileKind>{
          FileKind.md,
          FileKind.txt,
          FileKind.py,
          FileKind.css,
          FileKind.json,
          FileKind.csv,
        }.contains(kind)) {
      return _RealTextPreview(path: absolute, kind: kind);
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

String pathForRelative(String root, String relative) =>
    '$root${Platform.pathSeparator}${relative.replaceAll('/', Platform.pathSeparator)}';

class _RealTextPreview extends StatelessWidget {
  const _RealTextPreview({required this.path, required this.kind});

  final String path;
  final FileKind kind;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<String>(
      future: File(path).readAsString(),
      builder: (BuildContext context, AsyncSnapshot<String> snapshot) {
        if (snapshot.hasError) {
          return _Notice(
            icon: Icons.error_outline,
            text: '文件读取失败：${snapshot.error}',
          );
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final String text = snapshot.data!;
        if (kind == FileKind.md) {
          return BlocksView(blocks: parseMarkdownBlocks(text), gap: 12);
        }
        return CodeBlockView(block: CodeBlock(kind.name, text));
      },
    );
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
            '点击后将在浏览器中预览此 HTML 文件。',
            style: TextStyle(fontSize: 12, color: palette.text3),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => AppNav.openHtml(context, file: file),
            icon: const Icon(Icons.open_in_browser, size: 16),
            label: const Text('用浏览器打开'),
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
