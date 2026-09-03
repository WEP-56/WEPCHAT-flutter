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
}
