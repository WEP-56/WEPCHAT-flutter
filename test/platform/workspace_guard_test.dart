import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/platform/workspace_guard.dart';

/// 路径安全层的测试（实施 TODO §7-13、AGENTS.md §9）。
///
/// 这一层是唯一挡住"模型写到工作区外面"的东西，所以越界的每一种写法都要
/// 有一条测试。用真目录而不是假文件系统：符号链接和 `resolveSymbolicLinks`
/// 的行为是这层的核心，mock 掉就等于没测。
void main() {
  late Directory temp;
  late WorkspaceGuard guard;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('wep_guard_');
    guard = WorkspaceGuard(temp.path);
  });

  tearDown(() {
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  /// 断言路径被接受，并返回它。
  PathAllowed allowed(String raw, {bool allowRoot = false}) {
    final PathCheck check = guard.check(raw, allowRoot: allowRoot);
    expect(
      check,
      isA<PathAllowed>(),
      reason:
          '「$raw」本该被接受，却被拒了：'
          '${check is PathRejected ? check.reason : ''}',
    );
    return check as PathAllowed;
  }

  void rejected(String raw, {bool allowRoot = false, String? because}) {
    final PathCheck check = guard.check(raw, allowRoot: allowRoot);
    expect(check, isA<PathRejected>(), reason: because ?? '「$raw」本该被拒绝');
  }

  group('正常路径', () {
    test('相对路径通过，relative 用正斜杠', () {
      final PathAllowed a = allowed('notes.md');
      expect(a.relative, equals('notes.md'));
      expect(p.isWithin(temp.path, a.absolute), isTrue);

      expect(allowed('src/main.js').relative, equals('src/main.js'));
      expect(allowed(r'src\main.js').relative, equals('src/main.js'));
    });

    test('前后空白被忽略', () {
      expect(allowed('  notes.md  ').relative, equals('notes.md'));
    });

    test('工作区内的绝对路径通过', () {
      // 模型经常把 list_files 显示的路径原样抄回来。它在区内就该放行。
      final String inside = p.join(temp.path, 'a.txt');
      expect(allowed(inside).relative, equals('a.txt'));
    });

    test('内部的 .. 只要没跑出去就通过', () {
      expect(allowed('src/../notes.md').relative, equals('notes.md'));
    });

    test('allowRoot 决定根目录本身能不能过', () {
      expect(allowed('.', allowRoot: true).relative, isEmpty);
      expect(allowed('', allowRoot: true).relative, isEmpty);
      rejected('.', because: '文件类操作不该把目录当文件');
      rejected('');
    });
  });

  group('越界', () {
    test('.. 逃逸被拒', () {
      rejected('../outside.txt');
      rejected('../../etc/passwd');
      rejected('src/../../outside.txt');
      rejected(r'..\outside.txt');
    });

    test('工作区外的绝对路径被拒', () {
      rejected(p.join(temp.parent.path, 'outside.txt'));
    });

    test('前缀相同但不是子目录的兄弟目录被拒', () {
      // `<temp>` 和 `<temp>_evil` 的字符串前缀相同，纯 startsWith 会放行。
      rejected('${temp.path}_evil/a.txt');
    });

    test('UNC 与 \\\\?\\ 前缀被拒', () {
      rejected(r'\\?\C:\Windows\System32\drivers\etc\hosts');
      rejected(r'\\server\share\file.txt');
      rejected('//server/share/file.txt');
    });

    test('空字符被拒', () {
      rejected('notes\u0000.md');
    });
  });

  group('Windows 规则（所有平台一视同仁）', () {
    test('保留设备名被拒，带扩展名也一样', () {
      rejected('CON');
      rejected('nul.txt');
      rejected('src/COM1.log');
      rejected('LPT9');
    });

    test('保留名只是前缀时不拒', () {
      allowed('console.md');
      allowed('nullable.dart');
    });

    test('非法字符被拒', () {
      rejected('a<b.txt');
      rejected('a>b.txt');
      rejected('a:b.txt');
      rejected('a"b.txt');
      rejected('a|b.txt');
      rejected('a?b.txt');
      rejected('a*b.txt');
    });

    test('结尾的空格和点被拒', () {
      // Windows 会静默吃掉它们，写进去的名字和模型以为的不是同一个。
      // 整条路径两端的空白先被 trim 掉（那是格式噪声，不是文件名的一部分），
      // 所以这里测的是**中间段**和点结尾。
      rejected('dir /a.txt');
      rejected('a. /b.txt');
      rejected('notes.');
      rejected('src/notes.');
    });

    test('整条路径两端的空白按噪声处理，不算非法文件名', () {
      // trim 之后就是合法名字。拒掉的话，模型多打一个空格就得不到任何
      // 可操作的反馈，而它想要的那个文件名本身没有问题。
      expect(allowed('notes.md ').relative, equals('notes.md'));
    });
  });

  group('符号链接', () {
    test('指向工作区外的链接被拒', () {
      final Directory outside = Directory.systemTemp.createTempSync(
        'wep_outside_',
      );
      addTearDown(() {
        if (outside.existsSync()) outside.deleteSync(recursive: true);
      });
      File(p.join(outside.path, 'secret.txt')).writeAsStringSync('s3cret');

      final Link link = Link(p.join(temp.path, 'escape'));
      try {
        link.createSync(outside.path);
      } on FileSystemException {
        // Windows 上非管理员建不了目录链接。跳过而不是假装通过。
        return;
      }

      // 字面上完全在区内，只有解析链接之后才看得出越界。
      rejected('escape/secret.txt', because: '经链接指向了工作区外');
      rejected('escape');
    });

    test('指向工作区内的链接照常通过', () {
      Directory(p.join(temp.path, 'real')).createSync();
      File(p.join(temp.path, 'real', 'a.txt')).writeAsStringSync('ok');

      final Link link = Link(p.join(temp.path, 'alias'));
      try {
        link.createSync(p.join(temp.path, 'real'));
      } on FileSystemException {
        return; // 同上。
      }

      allowed('alias/a.txt');
    });

    test('还不存在的路径不受链接检查影响', () {
      // 待写入的新文件整条路径都不存在，没有链接可解析。
      allowed('new/deep/file.txt');
    });
  });

  test('根目录自己在链接下面时不误判', () {
    // macOS 的 /tmp 就是指向 /private/tmp 的链接。不先解析根，
    // 区内的路径会被当成越界。
    final Directory outer = Directory.systemTemp.createTempSync(
      'wep_realroot_',
    );
    addTearDown(() {
      if (outer.existsSync()) outer.deleteSync(recursive: true);
    });

    final Directory real = Directory(p.join(outer.path, 'real'))..createSync();
    File(p.join(real.path, 'a.txt')).writeAsStringSync('ok');

    final Link link = Link(p.join(outer.path, 'link'));
    try {
      link.createSync(real.path);
    } on FileSystemException {
      return;
    }

    final WorkspaceGuard linked = WorkspaceGuard(link.path);
    expect(linked.check('a.txt'), isA<PathAllowed>());
  });
}
