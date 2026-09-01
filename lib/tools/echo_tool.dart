/// Echo 工具，测试与演示用。
library;

import '../ai/provider_api.dart';
import 'tool.dart';

/// 原样返回输入的文本。用于测试工具调用流程。
class EchoTool extends Tool {
  const EchoTool();

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'echo',
        description: '原样返回输入的文本。用于测试工具调用流程。',
        schema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'message': <String, Object?>{
              'type': 'string',
              'description': '要回显的文本',
            },
          },
          'required': <String>['message'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final Object? msg = arguments['message'];
    if (msg is! String) {
      return ToolResult.error('message 必须是字符串');
    }
    return ToolResult.ok('Echo: $msg');
  }
}
