import 'package:flutter/material.dart';

import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/file_visuals.dart';
import '../widgets/toast.dart';
import '../../platform/open_file.dart';
import '../../platform/workspace_file_service.dart';
import '../../state/app_scope.dart';

/// 图片查看器。[gallery] 为同一会话的图片列表，可左右切换。
class ImageViewerScreen extends StatefulWidget {
  const ImageViewerScreen({
    super.key,
    required this.file,
    required this.gallery,
  });

  final String file;
  final List<String> gallery;

  @override
  State<ImageViewerScreen> createState() => _ImageViewerScreenState();
}

class _ImageViewerScreenState extends State<ImageViewerScreen> {
  late final List<String> _files = widget.gallery.contains(widget.file)
      ? List<String>.of(widget.gallery)
      : <String>[widget.file, ...widget.gallery];
  late int _index = _files.indexOf(widget.file);

  void _step(int delta) {
    setState(() {
      _index = (_index + delta) % _files.length;
      if (_index < 0) _index += _files.length;
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final String current = _files[_index];
    final bool multiple = _files.length > 1;

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
            FileIconBox(kind: fileKindFromName(current), size: 24, radius: 6),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                current,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.mono(size: 12.5, color: palette.text1),
              ),
            ),
          ],
        ),
        actions: <Widget>[
          if (multiple)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Center(
                child: Text(
                  '${_index + 1} / ${_files.length}',
                  style: AppFonts.mono(size: 11, color: palette.text3),
                ),
              ),
            ),
          IconAction(
            icon: Icons.download_outlined,
            tooltip: '导出',
            onTap: () async {
              final root = context.sessions.workspacePathFor(
                context.sessions.active.id,
              );
              final saved = await WorkspaceFileService(root).export(current);
              if (context.mounted) {
                showAppToast(context, saved.message);
              }
            },
          ),
          IconAction(
            icon: Icons.share_outlined,
            tooltip: '分享',
            onTap: () async {
              final root = context.sessions.workspacePathFor(
                context.sessions.active.id,
              );
              final ok = await shareFile(
                '$root/${current.replaceAll('/', '/')}',
              );
              if (context.mounted)
                showAppToast(context, ok ? '已打开分享面板' : '分享失败');
            },
          ),
          IconAction(
            icon: Icons.save_alt_outlined,
            tooltip: '保存到设备',
            onTap: () async {
              final root = context.sessions.workspacePathFor(
                context.sessions.active.id,
              );
              final saved = await WorkspaceFileService(root).export(current);
              if (context.mounted) {
                showAppToast(context, saved.message);
              }
            },
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            Expanded(
              child: Container(
                color: palette.bgSide,
                padding: const EdgeInsets.all(16),
                child: Center(
                  child: InteractiveViewer(
                    maxScale: 4,
                    child: WorkspaceImage(file: current),
                  ),
                ),
              ),
            ),
            if (multiple)
              Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                // 上方图片台是 bgSide，这条操作栏用 Scaffold 的 bg，靠色差分开。
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconAction(
                      icon: Icons.chevron_left,
                      tooltip: '上一张',
                      box: 40,
                      size: 22,
                      onTap: () => _step(-1),
                    ),
                    const SizedBox(width: 24),
                    IconAction(
                      icon: Icons.chevron_right,
                      tooltip: '下一张',
                      box: 40,
                      size: 22,
                      onTap: () => _step(1),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
