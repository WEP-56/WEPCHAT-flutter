import 'dart:typed_data';

/// 本地文档的只读预览数据，不携带第三方解析器类型。
sealed class DocumentPreview {
  const DocumentPreview();
}

final class PdfPreview extends DocumentPreview {
  const PdfPreview(this.bytes);
  final Uint8List bytes;
}

final class OfficePreview extends DocumentPreview {
  const OfficePreview(this.pages, {required this.isPresentation});
  final List<PreviewPage> pages;
  final bool isPresentation;
}

class PreviewPage {
  const PreviewPage(this.parts);
  final List<PreviewPart> parts;
}

/// 幻灯片使用原稿的点坐标（1 点 = 12700 EMU），UI 只做等比缩放。
final class SlidePreview extends PreviewPage {
  const SlidePreview({
    required this.width,
    required this.height,
    required this.background,
    required this.items,
    required this.notices,
  }) : super(const []);
  final double width, height;
  final int background;
  final List<SlideItem> items;
  final List<String> notices;
}

final class SlideBox {
  const SlideBox(this.x, this.y, this.width, this.height, {this.rotation = 0});
  final double x, y, width, height, rotation;
}

sealed class SlideItem {
  const SlideItem(this.box);
  final SlideBox box;
}

final class SlidePicture extends SlideItem {
  const SlidePicture(super.box, this.bytes);
  final Uint8List bytes;
}

enum SlideGeometry { rectangle, ellipse, rounded }

final class SlideShape extends SlideItem {
  const SlideShape(
    super.box, {
    this.fill,
    this.line,
    this.lineWidth = 1,
    this.geometry = SlideGeometry.rectangle,
  });
  final int? fill, line;
  final double lineWidth;
  final SlideGeometry geometry;
}

enum SlideAlignment { left, center, right, justify }

enum SlideAnchor { top, center, bottom }

final class SlideText extends SlideItem {
  const SlideText(
    super.box,
    this.paragraphs, {
    required this.anchor,
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
  });
  final List<SlideParagraph> paragraphs;
  final SlideAnchor anchor;
  final double left, top, right, bottom;
}

final class SlideParagraph {
  const SlideParagraph(
    this.runs, {
    required this.alignment,
    this.bullet,
    this.spaceBefore = 0,
    this.spaceAfter = 0,
  });
  final List<SlideRun> runs;
  final SlideAlignment alignment;
  final String? bullet;
  final double spaceBefore, spaceAfter;
}

final class SlideRun {
  const SlideRun(
    this.text, {
    required this.size,
    required this.color,
    required this.bold,
    required this.italic,
    this.font,
    this.eastAsianFont,
  });
  final String text;
  final double size;
  final int color;
  final bool bold, italic;
  final String? font, eastAsianFont;
}

sealed class PreviewPart {
  const PreviewPart();
}

final class PreviewText extends PreviewPart {
  const PreviewText(this.text);
  final String text;
}

final class PreviewImage extends PreviewPart {
  const PreviewImage(this.bytes);
  final Uint8List bytes;
}

final class PreviewNotice extends PreviewPart {
  const PreviewNotice(this.message);
  final String message;
}

final class DocumentPreviewException implements Exception {
  const DocumentPreviewException(this.message);
  final String message;
  @override
  String toString() => message;
}

final class DocumentPreviewCancelled implements Exception {
  const DocumentPreviewCancelled();
}
