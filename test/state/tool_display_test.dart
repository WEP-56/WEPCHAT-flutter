import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/messages.dart' as ai;
import 'package:wepchat/models/tool_call.dart';
import 'package:wepchat/state/tool_display.dart';
import 'package:wepchat/tools/tool.dart';

void main() {
  test('搜索结果恢复为可点击来源卡片', () {
    final ToolCall call = restoredToolCall(
      id: 'search-1',
      name: 'web_search',
      arguments: <String, Object?>{'query': 'Flutter'},
      content: '找到 1 条来源',
      outcome: ToolOutcome.ok,
      uiPayload: <String, Object?>{
        'results': <Object?>[
          <String, Object?>{
            'title': 'Flutter docs',
            'url': 'https://docs.flutter.dev/',
          },
        ],
      },
    );

    expect(call.sources, hasLength(1));
    expect(call.sources.single.url, equals('https://docs.flutter.dev/'));
    expect(call.sources.single.host, equals('docs.flutter.dev'));
  });

  test('edit_file 恢复为文件跳转与 diff 数据', () {
    final ToolCall call = finishedToolCall(
      const ai.ToolCallPart(
        id: 'edit-1',
        name: 'edit_file',
        arguments: <String, Object?>{'path': 'lib/main.dart'},
      ),
      ToolResult.ok(
        '已修改 lib/main.dart，替换了 1 处。',
        uiPayload: <String, Object?>{
          'path': 'lib/main.dart',
          'find': 'old();',
          'replace': 'new();',
          'replacements': 1,
        },
      ),
    );

    expect(call.file, equals('lib/main.dart'));
    expect(call.fileChange?.before, equals('old();'));
    expect(call.fileChange?.after, equals('new();'));
  });

  test('图片工具结果恢复为聊天图片产物', () {
    final ToolCall call = restoredToolCall(
      id: 'image-1',
      name: 'gen_image',
      arguments: const <String, Object?>{'prompt': '海边'},
      content: '图片生成完成',
      outcome: ToolOutcome.ok,
      uiPayload: const <String, Object?>{
        'paths': <String>['images/a.png', 'images/b.png'],
      },
    );

    expect(call.outputFiles, equals(<String>['images/a.png', 'images/b.png']));
  });

  test('HTML 写入结果恢复为独立预览产物', () {
    final ToolCall call = restoredToolCall(
      id: 'html-1',
      name: 'write_file',
      arguments: const <String, Object?>{'path': 'site/index.html'},
      content: '已创建 site/index.html',
      outcome: ToolOutcome.ok,
      uiPayload: const <String, Object?>{'path': 'site/index.html'},
    );

    expect(call.htmlFile, 'site/index.html');
  });

  test('run_js 写出的 HTML 恢复为独立预览产物', () {
    final ToolCall call = restoredToolCall(
      id: 'js-1',
      name: 'run_js',
      arguments: const <String, Object?>{'code': 'test'},
      content: 'done',
      outcome: ToolOutcome.ok,
      uiPayload: const <String, Object?>{
        'paths': <String>['data.json', 'report.html'],
      },
    );

    expect(call.htmlFile, 'report.html');
  });
}
