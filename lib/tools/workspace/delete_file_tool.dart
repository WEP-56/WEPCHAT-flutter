/// `delete_file`：删除工作区里的文件（功能协议 §5）。
library;

import 'dart:io';

import '../../ai/provider_api.dart';
import '../../platform/workspace_guard.dart';
import '../tool.dart';
import 'mutation_queue.dart';
import 'tool_args.dart';

class DeleteFileTool extends Tool {
  const DeleteFileTool();

  @override
  String get permissionId => 'delete_file';

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'delete_file',
        description:
            '删除工作区里的一个文件。删除不可恢复。'
            '只删单个文件，不删目录——要清空目录请逐个删。',
        schema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'path': <String, Object?>{
              'type': 'string',
              'description': '要删除的文件路径，相对工作区根。',
            },
          },
          'required': <String>['path'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final ArgReader args = ArgReader(arguments, context);
    final PathAllowed target = args.path();
    if (args.error != null) return args.error!;

    if (context.token.isCancelled) return ToolResult.cancelled();

    return MutationQueue.instance.run(
      context.workspace.root,
      () async => _delete(target, context),
    );
  }

  static Future<ToolResult> _delete(
    PathAllowed target,
    ToolContext context,
  ) async {
    if (context.token.isCancelled) return ToolResult.cancelled();

    // 不跟随链接判断类型：链接本身该被当成"一个文件"删掉，而不是顺着它
    // 去看指向的是不是目录。
    final FileSystemEntityType type =
        FileSystemEntity.typeSync(target.absolute, followLinks: false);

    switch (type) {
      case FileSystemEntityType.notFound:
        // 协议 §5：不得在返回前声称文件已经删除。文件本来就不在，
        // 如实说"没找到"，不说"已删除"——模型据此判断是不是搞错了路径。
        return ToolResult.error('文件不存在：${target.relative}，没有删除任何东西。');
      case FileSystemEntityType.directory:
        return ToolResult.error(
          '${target.relative} 是一个目录，这个工具只删文件。',
        );
      case FileSystemEntityType.file:
      case FileSystemEntityType.link:
      case FileSystemEntityType.pipe:
      case FileSystemEntityType.unixDomainSock:
        break;
    }

    try {
      File(target.absolute).deleteSync();
    } on FileSystemException catch (e) {
      return ToolResult.error('删除失败：${e.message}');
    }

    return ToolResult.ok(
      '已删除 ${target.relative}。',
      uiPayload: <String, Object?>{'path': target.relative},
    );
  }
}
