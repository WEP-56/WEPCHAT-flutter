import 'dart:io';
import 'package:pdfrx/pdfrx.dart';

import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../mock/file_bodies.dart';
import '../../models/content.dart';
import '../../models/workspace.dart';
import '../../platform/workspace_file_service.dart';
import '../../platform/document_preview_loader.dart';
import '../../models/document_preview.dart';
import '../../platform/open_file.dart';
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
              final saved = await WorkspaceFileService(path).export(file);
              if (context.mounted) {
                showAppToast(context, saved.message);
              }
            },
          ),
          IconAction(
            icon: Icons.share_outlined,
            tooltip: '分享',
            onTap: () async {
              final String root = context.sessions.workspacePathFor(
                context.sessions.active.id,
              );
              final bool ok = await shareFile(pathForRelative(root, file));
              if (context.mounted)
                showAppToast(context, ok ? '已打开分享面板' : '分享失败');
            },
          ),
          IconAction(
            icon: Icons.save_alt_outlined,
            tooltip: '保存到设备',
            onTap: () async {
              final String root = context.sessions.workspacePathFor(
                context.sessions.active.id,
              );
              final saved = await WorkspaceFileService(root).export(file);
              if (context.mounted) {
                showAppToast(context, saved.message);
              }
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
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
    );
  }

  Widget _buildContent(BuildContext context, FileKind kind) {
    if (kind == FileKind.other) {
      return const _Notice(
        icon: Icons.insert_drive_file_outlined,
        text: '暂不支持此文件类型的内置预览。可通过上方按钮导出或分享，使用其他应用打开。',
      );
    }

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

    if (<FileKind>{FileKind.pdf, FileKind.docx, FileKind.pptx}.contains(kind)) {
      final workspace = context.sessions.workspacePathFor(
        context.sessions.active.id,
      );
      return _DocumentPreview(
        path: pathForRelative(workspace, file),
        kind: kind,
      );
    }

    final String workspace = context.sessions.workspacePathFor(
      context.sessions.active.id,
    );
    final String absolute = pathForRelative(workspace, file);
    if (File(absolute).existsSync() &&
        <FileKind>{
          FileKind.md,
          FileKind.txt,
          FileKind.py,
          FileKind.js,
          FileKind.ts,
          FileKind.css,
          FileKind.yaml,
          FileKind.xml,
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

class _DocumentPreview extends StatefulWidget {
  const _DocumentPreview({required this.path, required this.kind});
  final String path;
  final FileKind kind;
  @override
  State<_DocumentPreview> createState() => _DocumentPreviewState();
}

class _DocumentPreviewState extends State<_DocumentPreview> {
  late final DocumentPreviewLoader loader;
  late final Future<DocumentPreview> future;
  @override
  void initState() {
    super.initState();
    loader = DocumentPreviewLoader();
    final file = File(widget.path);
    future = loader.load(file.parent.path, file.uri.pathSegments.last);
  }

  @override
  void dispose() {
    loader.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<DocumentPreview>(
    future: future,
    builder: (context, snapshot) {
      if (snapshot.hasError)
        return _Notice(icon: Icons.error_outline, text: '${snapshot.error}');
      if (!snapshot.hasData)
        return const Center(child: CircularProgressIndicator());
      final preview = snapshot.data!;
      if (preview is PdfPreview)
        return PdfViewer.data(preview.bytes, sourceName: widget.path);
      final office = preview as OfficePreview;
      return ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: office.pages.length,
        itemBuilder: (_, i) => _OfficePage(
          page: office.pages[i],
          number: i + 1,
          presentation: office.isPresentation,
        ),
      );
    },
  );
}

class _OfficePage extends StatelessWidget {
  const _OfficePage({
    required this.page,
    required this.number,
    required this.presentation,
  });
  final PreviewPage page;
  final int number;
  final bool presentation;
  @override
  Widget build(BuildContext context) => Card(
    margin: const EdgeInsets.only(bottom: 14),
    child: Padding(
      padding: const EdgeInsets.all(18),
      child: page is SlidePreview
          ? _NativeSlide(slide: page as SlidePreview, number: number)
          : presentation
          ? _SlideCanvas(page: page, number: number)
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(presentation ? '第 $number 页' : '文档内容'),
                const SizedBox(height: 10),
                ...page.parts.map(
                  (part) => switch (part) {
                    PreviewText(:final text) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text(
                        text,
                        style: const TextStyle(fontSize: 15, height: 1.55),
                      ),
                    ),
                    PreviewImage(:final bytes) => Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Image.memory(bytes),
                    ),
                    PreviewNotice(:final message) => Text(message),
                  },
                ),
              ],
            ),
    ),
  );
}

class _NativeSlide extends StatelessWidget {
  const _NativeSlide({required this.slide, required this.number});
  final SlidePreview slide;
  final int number;
  @override
  Widget build(BuildContext context) => AspectRatio(
    aspectRatio: slide.width / slide.height,
    child: LayoutBuilder(
      builder: (context, c) {
        final sx = c.maxWidth / slide.width, sy = c.maxHeight / slide.height;
        return ColoredBox(
          color: Color(slide.background),
          child: Stack(
            children: [
              ...slide.items.map((item) => _nativeItem(item, sx, sy)),
              if (slide.notices.isNotEmpty)
                Positioned(
                  left: 8,
                  bottom: 4,
                  child: Text(
                    slide.notices.join(' · '),
                    style: const TextStyle(fontSize: 9, color: Colors.orange),
                  ),
                ),
            ],
          ),
        );
      },
    ),
  );
  Widget _nativeItem(SlideItem item, double sx, double sy) {
    final b = item.box;
    final position = Positioned(
      left: b.x * sx,
      top: b.y * sy,
      width: b.width * sx,
      height: b.height * sy,
      child: _content(item),
    );
    return item.box.rotation == 0
        ? position
        : Transform.rotate(
            angle: item.box.rotation * 3.14159265359 / 180,
            child: position,
          );
  }

  Widget _content(SlideItem item) {
    if (item is SlidePicture) return Image.memory(item.bytes, fit: BoxFit.fill);
    if (item is SlideShape)
      return DecoratedBox(
        decoration: BoxDecoration(
          color: item.fill == null ? null : Color(item.fill!),
          border: item.line == null
              ? null
              : Border.all(color: Color(item.line!)),
          borderRadius: item.geometry == SlideGeometry.rounded
              ? BorderRadius.circular(8)
              : null,
        ),
      );
    final text = item as SlideText;
    return Padding(
      padding: const EdgeInsets.all(4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: text.paragraphs.map((p) {
          final spans = <TextSpan>[];
          if (p.bullet != null) spans.add(TextSpan(text: '${p.bullet} '));
          spans.addAll(
            p.runs.map(
              (r) => TextSpan(
                text: r.text,
                style: TextStyle(
                  color: Color(r.color),
                  fontSize: r.size,
                  fontWeight: r.bold ? FontWeight.bold : null,
                  fontStyle: r.italic ? FontStyle.italic : null,
                  fontFamily: r.eastAsianFont ?? r.font,
                ),
              ),
            ),
          );
          return RichText(text: TextSpan(children: spans));
        }).toList(),
      ),
    );
  }
}

class _SlideCanvas extends StatelessWidget {
  const _SlideCanvas({required this.page, required this.number});
  final PreviewPage page;
  final int number;
  @override
  Widget build(BuildContext context) {
    final image = page.parts.whereType<PreviewImage>().firstOrNull;
    final texts = page.parts.whereType<PreviewText>();
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (image != null) Image.memory(image.bytes, fit: BoxFit.cover),
          Padding(
            padding: const EdgeInsets.all(24),
            child: Align(
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .88),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '第 $number 页',
                          style: const TextStyle(
                            color: Colors.black54,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(height: 16),
                        ...texts.map(
                          (text) => Padding(
                            padding: const EdgeInsets.only(bottom: 10),
                            child: Text(
                              text.text,
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 18,
                                height: 1.35,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

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
        return SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: CodeBlockView(block: CodeBlock(kind.name, text)),
        );
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
