part of 'office_preview_parser.dart';

class _SlideParser {
  _SlideParser(this.package, this.width, this.height, this.themeDocument);
  final _OfficePackage package;
  final double width, height;
  final XmlDocument? themeDocument;

  SlidePreview parse(String name) {
    final doc = package.xml(name);
    final root = _child(_child(doc.rootElement, 'cSld'), 'spTree');
    if (root == null) throw const DocumentPreviewException('幻灯片内容缺失');
    final relations = package.relationships(name);
    final theme = _SlideTheme(themeDocument?.rootElement, null);
    final items = <SlideItem>[];
    final notices = <String>[];
    for (final node in root.childElements) {
      final local = node.name.local;
      if (local == 'sp') {
        final box = _box(node);
        if (box == null) {
          notices.add('有一个形状缺少位置，已跳过');
          continue;
        }
        final body = _child(node, 'txBody');
        final paragraphs = body == null
            ? const <SlideParagraph>[]
            : _paragraphs(
                body,
                const [],
                theme,
                title: _child(node, 'ph')?.getAttribute('type') == 'ctrTitle',
              );
        final fill = theme.color(_child(_child(node, 'spPr'), 'solidFill'));
        final line = theme.color(_child(_child(node, 'spPr'), 'ln'));
        if (body != null &&
            paragraphs.any((p) => p.runs.any((r) => r.text.isNotEmpty))) {
          items.add(
            SlideText(
              box,
              paragraphs,
              anchor: SlideAnchor.top,
              left: 0,
              top: 0,
              right: 0,
              bottom: 0,
            ),
          );
        } else if (fill != null || line != null) {
          items.add(
            SlideShape(box, fill: fill, line: line, geometry: _geometry(node)),
          );
        }
      } else if (local == 'pic') {
        final box = _box(node);
        final blip = _descendant(node, 'blip');
        final id = blip == null ? null : _attribute(blip, 'embed');
        final relation = id == null ? null : relations[id];
        if (box == null || relation == null || relation.external) {
          notices.add('有一个图片无法读取');
          continue;
        }
        try {
          items.add(
            SlidePicture(
              box,
              package.read(package.target(name, relation.target)),
            ),
          );
        } on Object {
          notices.add('有一个图片无法读取');
        }
      } else if (local == 'graphicFrame') {
        notices.add('图表或表格采用简化预览');
      }
    }
    if (items.isEmpty) notices.add('此页没有可识别的图形或文字');
    return SlidePreview(
      width: width,
      height: height,
      background: 0xffffffff,
      items: List.unmodifiable(items),
      notices: List.unmodifiable(notices),
    );
  }

  SlideBox? _box(XmlElement node) {
    final transform = _descendant(
      _child(node, 'spPr') ?? _child(node, 'picSpPr'),
      'xfrm',
    );
    final off = _child(transform, 'off');
    final ext = _child(transform, 'ext');
    if (off == null || ext == null) return null;
    final x = _number(off, 'x');
    final y = _number(off, 'y');
    final w = _number(ext, 'cx');
    final h = _number(ext, 'cy');
    return SlideBox(
      x / _emuPerPoint,
      y / _emuPerPoint,
      w / _emuPerPoint,
      h / _emuPerPoint,
      rotation: _number(transform, 'rot', defaultValue: 0) / 60000,
    );
  }

  SlideGeometry _geometry(XmlElement node) {
    final preset = _child(
      _child(node, 'spPr'),
      'prstGeom',
    )?.getAttribute('prst');
    return switch (preset) {
      'ellipse' => SlideGeometry.ellipse,
      'roundRect' => SlideGeometry.rounded,
      _ => SlideGeometry.rectangle,
    };
  }
}
