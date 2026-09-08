import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/models/workspace.dart';

void main() {
  test('未支持的类型不会被误认为可读取的纯文本', () {
    for (final String name in <String>[
      'slides.pptx',
      'report.DOCX',
      'data.xlsx',
      'archive.zip',
      'custom.unknown',
      'LICENSE',
      'folder.txt/README',
      '.env',
    ]) {
      expect(fileKindFromName(name), FileKind.other, reason: name);
    }
  });

  test('所有已支持类型均能识别且不区分大小写', () {
    for (final FileKind kind in FileKind.values) {
      if (kind == FileKind.other) continue;
      expect(fileKindFromName('file.${kind.name}'), kind);
      expect(fileKindFromName('file.${kind.name.toUpperCase()}'), kind);
    }
    expect(fileKindFromName('page.htm'), FileKind.html);
    expect(fileKindFromName('photo.jpeg'), FileKind.jpg);
    expect(fileKindFromName('config.yml'), FileKind.yaml);
  });
}
