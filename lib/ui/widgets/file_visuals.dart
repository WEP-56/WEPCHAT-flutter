import 'package:flutter/material.dart';

import '../../mock/mock_assets.dart';
import '../../models/workspace.dart';
import '../../theme/palette.dart';

IconData fileKindIcon(FileKind kind) {
  return switch (kind) {
    FileKind.md => Icons.description_outlined,
    FileKind.txt => Icons.notes_outlined,
    FileKind.csv => Icons.table_chart_outlined,
    FileKind.py => Icons.code,
    FileKind.css => Icons.palette_outlined,
    FileKind.json => Icons.data_object,
    FileKind.html => Icons.language,
    FileKind.png || FileKind.jpg => Icons.image_outlined,
    FileKind.pdf => Icons.picture_as_pdf_outlined,
  };
}

/// 从文件名推断类型。未知扩展名按纯文本展示（仅影响图标，不影响读取语义）。
FileKind fileKindFromName(String name) {
  final int dot = name.lastIndexOf('.');
  if (dot < 0 || dot == name.length - 1) return FileKind.txt;
  final String ext = name.substring(dot + 1).toLowerCase();
  final String normalized = ext == 'jpeg' ? 'jpg' : ext;
  for (final FileKind kind in FileKind.values) {
    if (kind.name == normalized) return kind;
  }
  return FileKind.txt;
}

/// 文件类型图标底板。
class FileIconBox extends StatelessWidget {
  const FileIconBox({
    super.key,
    required this.kind,
    this.size = 28,
    this.radius = 7,
  });

  final FileKind kind;
  final double size;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Icon(
          fileKindIcon(kind),
          size: size * 0.46,
          color: palette.text2,
        ),
      ),
    );
  }
}

/// 工作区图片。命中内置资源时显示真实图片，否则显示占位渐变。
class WorkspaceImage extends StatelessWidget {
  const WorkspaceImage({
    super.key,
    required this.file,
    this.aspectRatio = 16 / 9,
  });

  final String file;
  final double aspectRatio;

  static const List<List<Color>> _placeholderGradients = <List<Color>>[
    <Color>[Color(0xFF8B5E34), Color(0xFFD9A066)],
    <Color>[Color(0xFF2F5D50), Color(0xFF7FB295)],
    <Color>[Color(0xFF3B3B58), Color(0xFF8A7FB5)],
  ];

  @override
  Widget build(BuildContext context) {
    final String? asset = kWorkspaceImageAssets[file];
    final Widget content = asset == null
        ? _placeholder(context)
        : Image.asset(asset, fit: BoxFit.cover);

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: AspectRatio(aspectRatio: aspectRatio, child: content),
    );
  }

  Widget _placeholder(BuildContext context) {
    final int seed = file.codeUnits.fold<int>(0, (int a, int b) => a + b);
    final List<Color> colors =
        _placeholderGradients[seed % _placeholderGradients.length];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: colors,
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Center(
        child: Icon(
          Icons.image_outlined,
          size: 28,
          color: Colors.white.withValues(alpha: 0.7),
        ),
      ),
    );
  }
}
