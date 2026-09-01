import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/platform/workspace_paths.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wepchat_ws_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('resolve', () {
    test('空配置退到 fallback', () {
      expect(
        WorkspaceRoots.resolve('  ', fallback: root.path).root,
        equals(root.path),
      );
    });

    test('~ 被展开成主目录，不会建一个真叫 ~ 的目录', () {
      final WorkspaceRoots roots =
          WorkspaceRoots.resolve('~/WePChat/workspaces', fallback: root.path);

      expect(roots.root, isNot(contains('~')));
      expect(p.isAbsolute(roots.root), isTrue);
      expect(roots.root, contains('WePChat'));
    });

    test('相对路径被转成绝对路径', () {
      final WorkspaceRoots roots =
          WorkspaceRoots.resolve('ws/here', fallback: root.path);

      expect(p.isAbsolute(roots.root), isTrue);
      expect(p.basename(roots.root), equals('here'));
    });

    test('绝对路径原样保留（规范化后）', () {
      final String messy = p.join(root.path, 'a', '..', 'b');
      expect(
        WorkspaceRoots.resolve(messy, fallback: '/nope').root,
        equals(p.join(root.path, 'b')),
      );
    });
  });

  group('ensureSession', () {
    test('目录名是 session_id，不是标题', () {
      final WorkspaceRoots roots = WorkspaceRoots(root.path);
      final String path = roots.ensureSession('01HQ8ABCDEF');

      expect(p.basename(path), equals('01HQ8ABCDEF'));
      expect(Directory(path).existsSync(), isTrue);
    });

    test('幂等：重复调用不报错', () {
      final WorkspaceRoots roots = WorkspaceRoots(root.path);
      roots.ensureSession('s1');
      final String again = roots.ensureSession('s1');

      expect(Directory(again).existsSync(), isTrue);
    });

    test('根目录不存在时一并建出来', () {
      final WorkspaceRoots roots =
          WorkspaceRoots(p.join(root.path, 'deep', 'nested'));
      final String path = roots.ensureSession('s2');

      expect(Directory(path).existsSync(), isTrue);
    });

    test('pathFor 不碰磁盘', () {
      final WorkspaceRoots roots = WorkspaceRoots(root.path);
      final String path = roots.pathFor('s3');

      expect(Directory(path).existsSync(), isFalse);
      expect(path, equals(p.join(root.path, 's3')));
    });

    test('建不出来也不抛——新建会话不该被文件系统拦住', () async {
      // 用一个文件当根目录：在它下面建子目录必然失败。
      final File blocker = File(p.join(root.path, 'blocker'));
      await blocker.writeAsString('x');

      final WorkspaceRoots roots = WorkspaceRoots(blocker.path);
      final String path = roots.ensureSession('s4');

      expect(Directory(path).existsSync(), isFalse);
    });
  });
}
