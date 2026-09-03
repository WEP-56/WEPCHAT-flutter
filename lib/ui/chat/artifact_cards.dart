import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../models/chat.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/file_visuals.dart';
import '../widgets/toast.dart';

/// 工作区文件引用（消息底部的产物列表）。
class FileChip extends StatelessWidget {
  const FileChip({super.key, required this.file});

  final String file;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return InkWell(
      onTap: () => AppNav.openFile(context, file: file),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: palette.bgPanel,
          border: Border.all(color: palette.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FileIconBox(kind: fileKindFromName(file), size: 20, radius: 5),
            const SizedBox(width: 7),
            Text(file, style: AppFonts.mono(size: 11.5, color: palette.text1)),
          ],
        ),
      ),
    );
  }
}

/// 图片工具产物。
class ImageResultView extends StatelessWidget {
  const ImageResultView({
    super.key,
    required this.result,
    required this.gallery,
  });

  final ImageResult result;

  /// 当前会话的全部图片，供查看器左右切换。
  final List<String> gallery;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            onTap: () =>
                AppNav.openImage(context, file: result.file, gallery: gallery),
            borderRadius: BorderRadius.circular(10),
            child: WorkspaceImage(file: result.file),
          ),
          const SizedBox(height: 6),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${result.file} · ${result.meta}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.mono(size: 10.5, color: palette.text3),
                ),
              ),
              IconAction(
                icon: Icons.download_outlined,
                tooltip: '导出',
                size: 14,
                box: 26,
                onTap: () => showAppToast(context, '导出图片（预览版未接入文件系统）'),
              ),
              IconAction(
                icon: Icons.open_in_full,
                tooltip: '查看',
                size: 13,
                box: 26,
                onTap: () => AppNav.openImage(
                  context,
                  file: result.file,
                  gallery: gallery,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// HTML 产物卡片，点击进入应用内预览。
class HtmlArtifactCard extends StatelessWidget {
  const HtmlArtifactCard({super.key, required this.ref});

  final HtmlRef ref;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: InkWell(
        onTap: () => AppNav.openHtml(context, file: ref.file),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: palette.bgPanel,
            border: Border.all(color: palette.border),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            children: <Widget>[
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: palette.accentSoft,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(Icons.language, size: 20, color: palette.accent),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      ref.title,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: palette.text1,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ref.desc,
                      style: TextStyle(fontSize: 11.5, color: palette.text3),
                    ),
                  ],
                ),
              ),
              const Pill(
                '预览',
                tone: PillTone.accent,
                icon: Icons.open_in_browser,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
