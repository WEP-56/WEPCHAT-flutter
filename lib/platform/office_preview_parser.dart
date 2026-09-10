import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:xml/xml.dart';

import '../models/document_preview.dart';

part 'slide_preview_parser.dart';
part 'slide_preview_styles.dart';

const int _maxPartBytes = 16 * 1024 * 1024;
const int _maxExpandedBytes = 64 * 1024 * 1024;
const int _maxEntries = 4096;
const int _maxSlides = 500;

/// 只读 OOXML 包内内容，不解压到磁盘，也不访问外部关系资源。
/// 调用方必须在可终止的 worker isolate 中执行。
OfficePreview parseOfficePreview(Uint8List bytes, {required bool slides}) {
  try {
    final package = _OfficePackage(bytes);
    if (!slides) {
      return OfficePreview([
        package.page('word/document.xml'),
      ], isPresentation: false);
    }
    const main = 'ppt/presentation.xml';
    final document = package.xml(main);
    final relationships = package.relationships(main);
    XmlDocument? themeDocument;
    const themePath = 'ppt/theme/theme1.xml';
    if (package.contains(themePath)) themeDocument = package.xml(themePath);
    final ids = document.descendants.whereType<XmlElement>().where(
      (element) => element.name.local == 'sldId',
    );
    if (ids.length > _maxSlides) {
      throw const DocumentPreviewException('幻灯片超过 500 页，无法内置预览');
    }
    final pages = <PreviewPage>[];
    final size = _child(document.rootElement, 'sldSz');
    final width = _number(size, 'cx') / _emuPerPoint;
    final height = _number(size, 'cy') / _emuPerPoint;
    if (width <= 0 || height <= 0) {
      throw const DocumentPreviewException('幻灯片页面尺寸缺失或无效');
    }
    for (final id in ids) {
      final relationId = _attribute(id, 'id', namespaced: true);
      final relation = relationships[relationId];
      if (relation == null || relation.external) {
        throw const DocumentPreviewException('幻灯片页引用缺失或无效');
      }
      pages.add(
        _SlideParser(
          package,
          width,
          height,
          themeDocument,
        ).parse(package.target(main, relation.target)),
      );
    }
    if (pages.isEmpty) {
      throw const DocumentPreviewException('此演示文稿没有幻灯片');
    }
    return OfficePreview(List.unmodifiable(pages), isPresentation: true);
  } on DocumentPreviewException {
    rethrow;
  } on Object {
    // 解析器异常可能含 XML 正文；在基础设施边界转换，避免泄露文档内容。
    throw const DocumentPreviewException('Office 文档解析失败：文件损坏、加密或格式不受支持');
  }
}

String? _attribute(
  XmlElement element,
  String local, {
  bool namespaced = false,
}) {
  for (final attribute in element.attributes) {
    if (attribute.name.local == local &&
        (!namespaced || attribute.name.prefix != null)) {
      return attribute.value;
    }
  }
  return null;
}

class _Relationship {
  const _Relationship(this.target, this.external, this.type);
  final String target;
  final bool external;
  final String type;
}

class _OfficePackage {
  _OfficePackage(Uint8List bytes) {
    // 直接读取目录，避免 ZipDecoder 自动解压符号链接的内容。
    final directory = ZipDirectory()..read(InputMemoryStream(bytes));
    if (directory.fileHeaders.length > _maxEntries) {
      throw const DocumentPreviewException('文档内部文件过多，无法内置预览');
    }
    var total = 0;
    for (final header in directory.fileHeaders) {
      final file = header.file!;
      total += file.uncompressedSize;
      if (file.uncompressedSize > _maxPartBytes || total > _maxExpandedBytes) {
        throw const DocumentPreviewException('文档解压后超过预览大小限制');
      }
      if (_files.containsKey(file.filename)) {
        throw const DocumentPreviewException('文档包含重复的内部文件');
      }
      _files[file.filename] = file;
    }
  }

  final _files = <String, ZipFile>{};
  final _cache = <String, Uint8List>{};
  var _expandedBytes = 0;

  bool contains(String name) => _files.containsKey(name);

  Uint8List read(String name) {
    final cached = _cache[name];
    if (cached != null) return cached;
    final file = _files[name];
    if (file == null) {
      throw const DocumentPreviewException('文档缺少必要的内容或图片文件');
    }
    final output = _LimitedOutput(_maxPartBytes);
    file.decompress(output);
    final data = output.getBytes();
    _expandedBytes += data.length;
    if (_expandedBytes > _maxExpandedBytes) {
      throw const DocumentPreviewException('文档解压后超过预览大小限制');
    }
    if (data.length != file.uncompressedSize || getCrc32(data) != file.crc32) {
      throw const DocumentPreviewException('文档内部文件校验失败');
    }
    _cache[name] = data;
    return data;
  }

  XmlDocument xml(String name) => XmlDocument.parse(utf8.decode(read(name)));

  Map<String, _Relationship> relationships(String part) {
    final name = p.posix.join(
      p.posix.dirname(part),
      '_rels',
      '${p.posix.basename(part)}.rels',
    );
    // OOXML 没有外部引用的部件允许省略 .rels。
    if (!_files.containsKey(name)) return const {};
    final result = <String, _Relationship>{};
    for (final element in xml(name).rootElement.childElements) {
      if (element.name.local != 'Relationship') continue;
      final id = element.getAttribute('Id');
      final target = element.getAttribute('Target');
      if (id == null || target == null || result.containsKey(id)) {
        throw const DocumentPreviewException('文档内部关系格式错误');
      }
      result[id] = _Relationship(
        target,
        element.getAttribute('TargetMode') == 'External',
        element.getAttribute('Type') ?? '',
      );
    }
    return result;
  }

  String target(String part, String raw) {
    final uri = Uri.parse(raw);
    if (uri.hasScheme || uri.hasAuthority || uri.hasQuery || uri.hasFragment) {
      throw const DocumentPreviewException('文档内部引用路径无效');
    }
    final decoded = Uri.decodeComponent(uri.path);
    final resolved = p.posix.normalize(
      decoded.startsWith('/')
          ? decoded.substring(1)
          : p.posix.join(p.posix.dirname(part), decoded),
    );
    if (resolved == '..' ||
        resolved.startsWith('../') ||
        resolved.contains('\\')) {
      throw const DocumentPreviewException('文档内部引用越界');
    }
    return resolved;
  }

  PreviewPage page(String name) {
    final document = xml(name);
    final relations = relationships(name);
    final parts = <PreviewPart>[];
    final text = StringBuffer();
    void flush() {
      final value = text.toString().trim();
      if (value.isNotEmpty) parts.add(PreviewText(value));
      text.clear();
    }

    // 按 XML 阅读顺序提取；表格单元格以制表符分隔，保留段落与分页。
    void visit(XmlElement element) {
      final local = element.name.local;
      if (local == 't') {
        text.write(element.innerText);
        return;
      }
      if (local == 'tab') text.write('\t');
      if (local == 'br') text.writeln();
      if (local == 'blip') {
        flush();
        final id = _attribute(element, 'embed');
        if (id == null) {
          parts.add(const PreviewNotice('外部链接图片未加载'));
          return;
        }
        final relation = relations[id];
        if (relation == null) {
          throw const DocumentPreviewException('文档图片引用缺失');
        }
        if (relation.external) {
          parts.add(const PreviewNotice('外部链接图片未加载'));
          return;
        }
        final imagePath = target(name, relation.target);
        if (!{
          '.png',
          '.jpg',
          '.jpeg',
          '.gif',
          '.webp',
          '.bmp',
        }.contains(p.posix.extension(imagePath).toLowerCase())) {
          parts.add(const PreviewNotice('此图片格式暂不支持简化预览'));
          return;
        }
        parts.add(PreviewImage(read(imagePath)));
        return;
      }
      for (final child in element.childElements) {
        visit(child);
      }
      if (local == 'p' || local == 'tr') text.writeln();
      if (local == 'tc') text.write('\t');
    }

    visit(document.rootElement);
    flush();
    return PreviewPage(List.unmodifiable(parts));
  }
}

/// 不信任 ZIP 声明的大小：每种解压写入都在扩容前检查实际字节数。
class _LimitedOutput extends OutputMemoryStream {
  _LimitedOutput(this.limit);
  final int limit;

  void _check(int count) {
    if (count < 0 || length + count > limit) {
      throw const DocumentPreviewException('文档内部文件超过解压大小限制');
    }
  }

  @override
  void writeByte(int value) {
    _check(1);
    super.writeByte(value);
  }

  @override
  void writeBytes(List<int> bytes, {int? length}) {
    _check(length ?? bytes.length);
    super.writeBytes(bytes, length: length);
  }

  @override
  void writeStream(InputStream stream) {
    _check(stream.length);
    super.writeStream(stream);
  }

  @override
  void writeBackReference(int distance, int count) {
    _check(count);
    super.writeBackReference(distance, count);
  }
}
