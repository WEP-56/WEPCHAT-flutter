part of 'office_preview_parser.dart';

const double _emuPerPoint = 12700;

XmlElement? _child(XmlElement? parent, String name) =>
    parent?.childElements.where((e) => e.name.local == name).firstOrNull;

XmlElement? _descendant(XmlElement? parent, String name) => parent?.descendants
    .whereType<XmlElement>()
    .where((e) => e.name.local == name)
    .firstOrNull;

double _number(XmlElement? e, String key, {double? defaultValue}) {
  final raw = e?.getAttribute(key);
  if (raw == null && defaultValue != null) return defaultValue;
  final value = double.tryParse(raw ?? '');
  if (value == null || !value.isFinite) {
    throw const DocumentPreviewException('幻灯片包含无效的尺寸或样式数值');
  }
  return value;
}

class _SlideTheme {
  _SlideTheme(this.root, XmlElement? mapping) {
    if (mapping != null) {
      for (final attribute in mapping.attributes) {
        colorMap[attribute.name.local] = attribute.value;
      }
    }
  }
  final XmlElement? root;
  final colorMap = <String, String>{
    'bg1': 'lt1',
    'tx1': 'dk1',
    'bg2': 'lt2',
    'tx2': 'dk2',
  };

  int? color(XmlElement? container) {
    if (container == null) return null;
    final node = container.childElements
        .where((e) => {'srgbClr', 'schemeClr', 'sysClr'}.contains(e.name.local))
        .firstOrNull;
    if (node == null) return null;
    String? hex;
    if (node.name.local == 'schemeClr') {
      final key = node.getAttribute('val');
      final scheme = _descendant(root, 'clrScheme');
      final entry = _child(scheme, colorMap[key] ?? key ?? '');
      final rgb = _child(entry, 'srgbClr');
      hex =
          rgb?.getAttribute('val') ??
          _child(entry, 'sysClr')?.getAttribute('lastClr');
      // OOXML's standard dark/light defaults when no theme is supplied.
      hex ??= switch (colorMap[key] ?? key) {
        'dk1' => '000000',
        'lt1' => 'FFFFFF',
        _ => null,
      };
    } else {
      hex = node.getAttribute(node.name.local == 'sysClr' ? 'lastClr' : 'val');
    }
    if (hex == null || !RegExp(r'^[0-9A-Fa-f]{6}$').hasMatch(hex)) return null;
    final rgb = int.parse(hex, radix: 16);
    var channels = [(rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255];
    var alpha = 255;
    for (final transform in node.childElements) {
      final amount = _number(transform, 'val', defaultValue: 100000) / 100000;
      switch (transform.name.local) {
        case 'tint':
          channels = channels
              .map((c) => (c + (255 - c) * amount).round().clamp(0, 255))
              .toList();
        case 'shade':
        case 'lumMod':
          channels = channels
              .map((c) => (c * amount).round().clamp(0, 255))
              .toList();
        case 'lumOff':
          channels = channels
              .map((c) => (c + 255 * amount).round().clamp(0, 255))
              .toList();
        case 'alpha':
          alpha = (amount * 255).round().clamp(0, 255);
      }
    }
    return (alpha << 24) |
        (channels[0] << 16) |
        (channels[1] << 8) |
        channels[2];
  }

  String? font(
    String? typeface, {
    required bool eastAsian,
    required bool title,
  }) {
    if (typeface != null && typeface.isNotEmpty && !typeface.startsWith('+'))
      return typeface;
    final major = typeface?.startsWith('+mj') ?? title;
    final collection = _descendant(root, major ? 'majorFont' : 'minorFont');
    var value = _child(
      collection,
      eastAsian ? 'ea' : 'latin',
    )?.getAttribute('typeface');
    if (eastAsian && (value == null || value.isEmpty)) {
      value = collection?.childElements
          .where(
            (e) => e.name.local == 'font' && e.getAttribute('script') == 'Hans',
          )
          .firstOrNull
          ?.getAttribute('typeface');
    }
    return value == null || value.isEmpty ? null : value;
  }
}

/// 按直接格式 → 版式 → 母版的顺序读取段落与 run 样式。
List<SlideParagraph> _paragraphs(
  XmlElement body,
  List<XmlElement> inherited,
  _SlideTheme theme, {
  required bool title,
}) {
  final result = <SlideParagraph>[];
  for (final paragraph in body.childElements.where(
    (e) => e.name.local == 'p',
  )) {
    final props = _child(paragraph, 'pPr');
    final level = _number(props, 'lvl', defaultValue: 0).toInt() + 1;
    final defaults = <XmlElement>[
      if (props != null) props,
      for (final list in [_child(body, 'lstStyle'), ...inherited])
        if (_child(list, 'lvl${level}pPr') case final XmlElement found) found,
    ];
    String? paragraphAttribute(String key) => defaults
        .map((e) => e.getAttribute(key))
        .whereType<String>()
        .firstOrNull;
    double spacing(String name) {
      for (final d in defaults) {
        final points = _child(_child(d, name), 'spcPts');
        if (points != null) return _number(points, 'val') / 100;
      }
      return 0;
    }

    final runs = <SlideRun>[];
    for (final run in paragraph.childElements) {
      if (!{'r', 'fld', 'br'}.contains(run.name.local)) continue;
      final styles = <XmlElement>[
        if (_child(run, 'rPr') case final XmlElement r) r,
        for (final d in defaults)
          if (_child(d, 'defRPr') case final XmlElement r) r,
      ];
      String? attr(String key) => styles
          .map((e) => e.getAttribute(key))
          .whereType<String>()
          .firstOrNull;
      String? face(String name) => styles
          .map((e) => _child(e, name)?.getAttribute('typeface'))
          .whereType<String>()
          .firstOrNull;
      final color =
          styles
              .map((e) => theme.color(_child(e, 'solidFill')))
              .whereType<int>()
              .firstOrNull ??
          0xff000000;
      final sizeRaw = attr('sz');
      final size = sizeRaw == null
          ? (title ? 32.0 : 18.0)
          : double.parse(sizeRaw) / 100;
      if (!size.isFinite || size <= 0) {
        throw const DocumentPreviewException('幻灯片文字大小无效');
      }
      runs.add(
        SlideRun(
          run.name.local == 'br' ? '\n' : _child(run, 't')?.innerText ?? '',
          size: size,
          color: color,
          bold: {'1', 'true'}.contains(attr('b')),
          italic: {'1', 'true'}.contains(attr('i')),
          font: theme.font(face('latin'), eastAsian: false, title: title),
          eastAsianFont: theme.font(face('ea'), eastAsian: true, title: title),
        ),
      );
    }
    String? bullet;
    for (final d in defaults) {
      if (_child(d, 'buNone') != null) break;
      final char = _child(d, 'buChar')?.getAttribute('char');
      if (char != null) {
        bullet = char;
        break;
      }
      if (_child(d, 'buAutoNum') != null) {
        bullet = '${result.length + 1}.';
        break;
      }
    }
    result.add(
      SlideParagraph(
        List.unmodifiable(runs),
        bullet: bullet,
        spaceBefore: spacing('spcBef'),
        spaceAfter: spacing('spcAft'),
        alignment: switch (paragraphAttribute('algn')) {
          'ctr' => SlideAlignment.center,
          'r' => SlideAlignment.right,
          'just' => SlideAlignment.justify,
          _ => SlideAlignment.left,
        },
      ),
    );
  }
  return List.unmodifiable(result);
}
