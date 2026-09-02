import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:wepchat/tools/tool.dart';
import 'package:wepchat/tools/workspace/list_files_tool.dart';
import 'package:wepchat/tools/workspace/read_file_tool.dart';
import 'package:wepchat/tools/workspace/search_files_tool.dart';

import 'workspace_tool_harness.dart';

/// 三个读类工具(AGENTS.md §9:正常结果、参数错误、越界路径、取消)。
void main() {
  late ToolHarness h;

  setUp(() => h = ToolHarness.create());
  tearDown(() => h.dispose());

  group('list_files', () {
    const ListFilesTool tool = ListFilesTool();

    test('列出文件与目录，路径相对工作区根', () async {
      h.write('a.txt', 'hello');
      h.write('src/main.js', 'code');

      final ToolResult r = await tool.execute(<String, Object?>{}, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(r.content, contains('a.txt'));
      expect(r.content, contains('src/'));
      expect(r.content, contains('src/main.js'));
      // 绝对路径不该进模型上下文（AGENTS.md §5.1）。
      expect(r.content, isNot(contains(h.root)));
    });

    test('recursive=false 只列一层', () async {
      h.write('a.txt', 'x');
      h.write('src/main.js', 'y');

      final ToolResult r = await tool.execute(<String, Object?>{
        'recursive': false,
      }, h.context);

      expect(r.content, contains('a.txt'));
      expect(r.content, isNot(contains('main.js')));
    });

    test('字符串形式的布尔被接受', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'recursive': 'false',
      }, h.context);
      expect(r.outcome, ToolOutcome.ok);
    });

    test('布尔给了别的类型就报错，不猜', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'recursive': 3,
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('recursive'));
    });

    test('空目录说清楚是空的', () async {
      final ToolResult r = await tool.execute(<String, Object?>{}, h.context);
      expect(r.content, contains('空目录'));
    });

    test('越界路径被拒', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': '../',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
    });

    test('目录不存在时报错', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'nope',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('不存在'));
    });

    test('同一个目录两次列出顺序一致', () async {
      for (int i = 0; i < 12; i++) {
        h.write('f$i.txt', 'x');
      }
      final ToolResult a = await tool.execute(<String, Object?>{}, h.context);
      final ToolResult b = await tool.execute(<String, Object?>{}, h.context);
      expect(a.content, equals(b.content));
    });

    test('指向工作区外的链接不出现在结果里', () async {
      h.write('real.txt', 'x');
      if (!h.linkTo(h.outsidePath('secret.txt'), 'escape')) return;

      final ToolResult r = await tool.execute(<String, Object?>{}, h.context);
      // 列出来模型就会去读它，然后被守卫拒掉——那是一条自相矛盾的反馈。
      expect(r.content, isNot(contains('escape')));
      expect(r.content, contains('real.txt'));
    });
  });

  group('read_file', () {
    const ReadFileTool tool = ReadFileTool();

    test('返回带行号的正文', () async {
      h.write('a.txt', 'one\ntwo\nthree');

      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(r.content, contains('1\tone'));
      expect(r.content, contains('3\tthree'));
      expect(r.content, contains('共 3 行'));
    });

    test('lines 支持区间、开区间和单行', () async {
      h.write('a.txt', List<String>.generate(10, (int i) => 'L$i').join('\n'));

      final ToolResult range = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'lines': '2-3',
      }, h.context);
      expect(range.content, contains('L1'));
      expect(range.content, contains('L2'));
      expect(range.content, isNot(contains('L3')));

      final ToolResult open = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'lines': '9-',
      }, h.context);
      expect(open.content, contains('L8'));
      expect(open.content, contains('L9'));
      expect(open.content, isNot(contains('L7')));

      final ToolResult single = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'lines': '5',
      }, h.context);
      expect(single.content, contains('L4'));
      expect(single.content, isNot(contains('L5')));
    });

    test('lines 格式不对时报错', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'lines': '一到八十',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('lines'));
    });

    test('BOM 不出现在正文里', () async {
      h.writeBytes('bom.txt', <int>[0xEF, 0xBB, 0xBF, ...'hi'.codeUnits]);
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'bom.txt',
      }, h.context);
      expect(r.content, contains('1\thi'));
      expect(r.content, isNot(contains('﻿')));
    });

    test('二进制文件被拒而不是乱码', () async {
      h.writeBytes('img.png', <int>[0x89, 0x50, 0x00, 0x01, 0x02]);
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'img.png',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('二进制'));
    });

    test('文件不存在时报错', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'nope.txt',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('不存在'));
    });

    test('缺 path 报错', () async {
      final ToolResult r = await tool.execute(<String, Object?>{}, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('path'));
    });

    test('越界路径被拒且不读到文件', () async {
      final File outside = File(h.outsidePath('secret.txt'))
        ..writeAsStringSync('s3cret');

      final ToolResult r = await tool.execute(<String, Object?>{
        'path': '../${p.basename(outside.path)}',
      }, h.context);

      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, isNot(contains('s3cret')));
    });

    test('已取消时返回 cancelled 而不是失败', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
      }, h.cancelledContext());
      expect(r.outcome, ToolOutcome.cancelled);
    });
  });

  group('search_files', () {
    const SearchFilesTool tool = SearchFilesTool();

    test('返回路径、行号和命中行', () async {
      h.write('a.md', 'hello world\nsecond line');
      h.write('b.md', 'nothing here');

      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'world',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(r.content, contains('a.md:1'));
      expect(r.content, contains('hello world'));
      expect(r.content, isNot(contains('b.md')));
    });

    test('普通查询不把元字符当正则', () async {
      h.write('a.txt', r'price is $9.99');
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': r'$9.99',
      }, h.context);
      expect(r.content, contains('a.txt:1'));
    });

    test('use_regex 时按正则搜', () async {
      h.write('a.txt', 'foo123bar');
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': r'foo\d+bar',
        'use_regex': true,
      }, h.context);
      expect(r.content, contains('a.txt:1'));
    });

    test('正则不合法时报错而不是崩', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': '([',
        'use_regex': true,
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('正则'));
    });

    test('glob 过滤文件名', () async {
      h.write('a.md', 'target');
      h.write('b.txt', 'target');
      h.write('deep/c.md', 'target');

      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'target',
        'glob': '**/*.md',
      }, h.context);

      expect(r.content, contains('a.md'));
      expect(r.content, contains('deep/c.md'));
      expect(r.content, isNot(contains('b.txt')));
    });

    test('跳过二进制文件', () async {
      h.writeBytes('img.png', <int>[0x00, 0x01, ...'target'.codeUnits]);
      h.write('a.txt', 'target');

      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'target',
      }, h.context);

      expect(r.content, contains('a.txt'));
      expect(r.content, isNot(contains('img.png')));
    });

    test('没有命中时说清楚', () async {
      h.write('a.txt', 'hello');
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'zzz',
      }, h.context);
      expect(r.outcome, ToolOutcome.ok);
      expect(r.content, contains('没有找到'));
    });

    test('max_matches 生效并提示还有更多', () async {
      for (int i = 0; i < 20; i++) {
        h.write('f$i.txt', 'target');
      }
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'target',
        'max_matches': 3,
      }, h.context);
      expect(r.content, contains('上限'));
    });

    test('缺 query 报错', () async {
      final ToolResult r = await tool.execute(<String, Object?>{}, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('query'));
    });

    test('越界的 path 被拒', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'x',
        'path': '../',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
    });

    test('已取消时返回 cancelled', () async {
      h.write('a.txt', 'target');
      final ToolResult r = await tool.execute(<String, Object?>{
        'query': 'target',
      }, h.cancelledContext());
      expect(r.outcome, ToolOutcome.cancelled);
    });
  });
}
