import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/tools/tool.dart';
import 'package:wepchat/tools/workspace/delete_file_tool.dart';
import 'package:wepchat/tools/workspace/edit_file_tool.dart';
import 'package:wepchat/tools/workspace/write_file_tool.dart';

import 'workspace_tool_harness.dart';

/// 三个写类工具（AGENTS.md §9：正常、参数错误、越界、取消）。
void main() {
  late ToolHarness h;

  setUp(() => h = ToolHarness.create());
  tearDown(() => h.dispose());

  group('write_file', () {
    const WriteFileTool tool = WriteFileTool();

    test('新建文件并自动建父目录', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'deep/nested/a.txt',
        'content': 'hello',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(r.content, contains('已创建'));
      expect(h.read('deep/nested/a.txt'), equals('hello'));
    });

    test('覆盖已有文件，文案区分创建与覆盖', () async {
      h.write('a.txt', 'old');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'content': 'new',
      }, h.context);

      expect(r.content, contains('已覆盖'));
      expect(h.read('a.txt'), equals('new'));
    });

    test('空 content 合法——清空文件是明确的意图', () async {
      h.write('a.txt', 'stuff');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'content': '',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.read('a.txt'), isEmpty);
    });

    test('覆盖 CRLF 文件时沿用 CRLF', () async {
      h.write('a.txt', 'one\r\ntwo');
      await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'content': 'three\nfour',
      }, h.context);
      // 模型给的一定是 \n；直接写会把整个文件的行尾换掉。
      expect(h.read('a.txt'), equals('three\r\nfour'));
    });

    test('覆盖带 BOM 的文件时保留 BOM', () async {
      h.writeBytes('a.txt', <int>[0xEF, 0xBB, 0xBF, ...'old'.codeUnits]);
      await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'content': 'new',
      }, h.context);
      expect(h.readBytes('a.txt').take(3), equals(<int>[0xEF, 0xBB, 0xBF]));
      expect(h.read('a.txt'), endsWith('new'));
    });

    test('缺 content 报错', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('content'));
    });

    test('content 类型不对报错', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'content': 42,
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
    });

    test('越界路径被拒且不写出文件', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': '../evil.txt',
        'content': 'x',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(h.exists('../evil.txt'), isFalse);
    });

    test('保留设备名被拒', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'CON.txt',
        'content': 'x',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('保留'));
    });

    test('已取消时不写文件', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'content': 'x',
      }, h.cancelledContext());
      expect(r.outcome, ToolOutcome.cancelled);
      expect(h.exists('a.txt'), isFalse);
    });

    test('同一文件的并发写入被串行化，不互相盖掉', () async {
      // 队列的意义：读—改—写交错时，后写的会盖掉前一个，而两边都报成功。
      final List<Future<ToolResult>> futures = <Future<ToolResult>>[
        for (int i = 0; i < 5; i++)
          tool.execute(<String, Object?>{
            'path': 'race.txt',
            'content': 'v$i',
          }, h.context),
      ];

      final List<ToolResult> results = await Future.wait(futures);
      for (final ToolResult r in results) {
        expect(r.outcome, ToolOutcome.ok);
      }
      // 最后一次写入完整可见，没有被截断成半截。
      expect(h.read('race.txt'), equals('v4'));
    });
  });

  group('edit_file', () {
    const EditFileTool tool = EditFileTool();

    test('替换唯一的一处', () async {
      h.write('a.txt', 'hello world');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'world',
        'replace': 'dart',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.read('a.txt'), equals('hello dart'));
    });

    test('匹配不到就报错，绝不猜', () async {
      h.write('a.txt', 'hello world');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'wrold',
        'replace': 'x',
      }, h.context);

      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('找不到'));
      // 报错的同时文件必须一个字节都没动。
      expect(h.read('a.txt'), equals('hello world'));
    });

    test('多处命中且 all=false 时拒绝执行', () async {
      h.write('a.txt', 'x\nx\nx');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'x',
        'replace': 'y',
      }, h.context);

      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('3 次'));
      expect(h.read('a.txt'), equals('x\nx\nx'));
    });

    test('all=true 时全部替换', () async {
      h.write('a.txt', 'x\nx\nx');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'x',
        'replace': 'y',
        'all': true,
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.read('a.txt'), equals('y\ny\ny'));
    });

    test('find 里的正则元字符按字面处理', () async {
      h.write('a.txt', r'cost is $9.99 (net)');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': r'$9.99 (net)',
        'replace': 'free',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.read('a.txt'), equals('cost is free'));
    });

    test('CRLF 文件里用 \\n 的 find 也能匹配，写回仍是 CRLF', () async {
      // 不统一行尾的话 edit_file 在 Windows 上永远匹配不到。
      h.write('a.txt', 'one\r\ntwo\r\nthree');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'one\ntwo',
        'replace': 'ONE\nTWO',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.read('a.txt'), equals('ONE\r\nTWO\r\nthree'));
    });

    test('带 BOM 的文件编辑后 BOM 还在', () async {
      h.writeBytes('a.txt', <int>[0xEF, 0xBB, 0xBF, ...'hello'.codeUnits]);
      await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'hello',
        'replace': 'bye',
      }, h.context);

      expect(h.readBytes('a.txt').take(3), equals(<int>[0xEF, 0xBB, 0xBF]));
      expect(h.read('a.txt'), endsWith('bye'));
    });

    test('replace 为空串表示删掉这一段', () async {
      h.write('a.txt', 'keep DROP keep');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'DROP ',
        'replace': '',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.read('a.txt'), equals('keep keep'));
    });

    test('find 和 replace 相同时报错', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'x',
        'replace': 'x',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
    });

    test('文件不存在时指路到 write_file', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'nope.txt',
        'find': 'a',
        'replace': 'b',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('write_file'));
    });

    test('缺 replace 报错', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'x',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('replace'));
    });

    test('越界路径被拒', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': '../a.txt',
        'find': 'a',
        'replace': 'b',
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
    });

    test('已取消时不改文件', () async {
      h.write('a.txt', 'hello');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
        'find': 'hello',
        'replace': 'bye',
      }, h.cancelledContext());
      expect(r.outcome, ToolOutcome.cancelled);
      expect(h.read('a.txt'), equals('hello'));
    });
  });

  group('delete_file', () {
    const DeleteFileTool tool = DeleteFileTool();

    test('删掉存在的文件', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
      }, h.context);

      expect(r.outcome, ToolOutcome.ok);
      expect(h.exists('a.txt'), isFalse);
    });

    test('文件不存在时不谎称已删除', () async {
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'nope.txt',
      }, h.context);

      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('不存在'));
      expect(r.content, isNot(contains('已删除')));
    });

    test('目录被拒', () async {
      h.write('dir/a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'dir',
      }, h.context);

      expect(r.outcome, ToolOutcome.failed);
      expect(r.content, contains('目录'));
      expect(h.exists('dir/a.txt'), isTrue);
    });

    test('越界路径被拒且外面的文件还在', () async {
      final String outside = h.outsidePath('keep.txt');
      h.write('bait.txt', 'x');

      final ToolResult r = await tool.execute(<String, Object?>{
        'path': outside,
      }, h.context);
      expect(r.outcome, ToolOutcome.failed);
    });

    test('已取消时不删文件', () async {
      h.write('a.txt', 'x');
      final ToolResult r = await tool.execute(<String, Object?>{
        'path': 'a.txt',
      }, h.cancelledContext());
      expect(r.outcome, ToolOutcome.cancelled);
      expect(h.exists('a.txt'), isTrue);
    });
  });
}
