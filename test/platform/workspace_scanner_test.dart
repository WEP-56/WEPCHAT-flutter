import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wepchat/models/workspace.dart';
import 'package:wepchat/platform/workspace_scanner.dart';

void main() {
  late Directory workspace;

  setUp(() async {
    workspace = await Directory.systemTemp.createTemp('wep_workspace_scan_');
  });

  tearDown(() async {
    await workspace.delete(recursive: true);
  });

  Future<void> addFile(String relative) async {
    final File file = File(p.join(workspace.path, relative));
    await file.parent.create(recursive: true);
    // Binary bytes ensure enumeration does not depend on text decoding.
    await file.writeAsBytes(<int>[0x50, 0x4b, 0x03, 0x04, 0xff]);
  }

  test('Office、压缩包、任意扩展名及无扩展名文件全部可见', () async {
    const List<String> names = <String>[
      '演示文稿.pptx',
      'documents/REPORT.PPTX',
      'documents/report.docx',
      'tables/data.xlsx',
      'archive.zip',
      'animation.gif',
      'image.webp',
      'custom.wep-data',
      'folder.with.dots/LICENSE',
      '.env',
    ];
    for (final String name in names) {
      await addFile(name);
    }
    await Directory(p.join(workspace.path, 'empty')).create();

    final List<WorkspaceFile> files = await scanWorkspaceDirectory(
      workspace.path,
    );
    expect(
      files.map((WorkspaceFile file) => file.name),
      unorderedEquals(names),
    );
    expect(
      files.every((WorkspaceFile file) => file.kind == FileKind.other),
      isTrue,
    );
    expect(files.every((WorkspaceFile file) => file.size == '5 B'), isTrue);
  });

  test('原有预览类型与扩展名别名使用同一份识别规则', () async {
    const Map<String, FileKind> expected = <String, FileKind>{
      'notes.md': FileKind.md,
      'script.js': FileKind.js,
      'source.ts': FileKind.ts,
      'config.yaml': FileKind.yaml,
      'config.YML': FileKind.yaml,
      'data.xml': FileKind.xml,
      'page.HTM': FileKind.html,
      'photos/PHOTO.JPEG': FileKind.jpg,
      'photos/cover.png': FileKind.png,
    };
    for (final String name in expected.keys) {
      await addFile(name);
    }

    final List<WorkspaceFile> files = await scanWorkspaceDirectory(
      workspace.path,
    );
    expect(<String, FileKind>{
      for (final WorkspaceFile file in files) file.name: file.kind,
    }, expected);
  });

  test('可选地返回空目录，供工作区文件树展示', () async {
    await Directory(
      p.join(workspace.path, 'assets', 'icons'),
    ).create(recursive: true);
    await addFile('assets/readme.txt');

    final List<WorkspaceFile> entries = await scanWorkspaceDirectory(
      workspace.path,
      includeDirectories: true,
    );

    expect(
      entries
          .where((WorkspaceFile entry) => entry.isDirectory)
          .map((WorkspaceFile entry) => entry.name),
      unorderedEquals(<String>['assets', 'assets/icons']),
    );
    expect(
      entries
          .where((WorkspaceFile entry) => !entry.isDirectory)
          .map((WorkspaceFile entry) => entry.name),
      contains('assets/readme.txt'),
    );
  });
}
