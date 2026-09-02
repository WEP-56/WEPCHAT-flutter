/// `write_file`：新建或整体重写一个文件（功能协议 §5）。
library;

import 'dart:convert';
import 'dart:io';

import '../../ai/provider_api.dart';
import '../../platform/workspace_guard.dart';
import '../tool.dart';
import 'mutation_queue.dart';
import 'text_file.dart';
import 'tool_args.dart';

class WriteFileTool extends Tool {
  const WriteFileTool();

  @override
  String get permissionId => 'write_file';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'write_file',
    description:
        '把完整内容写进工作区里的一个文件，父目录会自动创建。'
        '适合新建文件或整体重写；只改其中一段请用 edit_file。'
        '覆盖已有文件会丢掉原内容，覆盖前应先 read_file 确认。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'path': <String, Object?>{
          'type': 'string',
          'description': '文件路径，相对工作区根。',
        },
        'content': <String, Object?>{
          'type': 'string',
          'description': '完整的文件内容。',
        },
      },
      'required': <String>['path', 'content'],
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

    // content 单独取：允许空串（"清空这个文件"是合法意图），
    // 所以不能走 requireString。
    final Object? rawContent = arguments['content'];
    if (rawContent == null) return ToolResult.error('缺少必填参数 content');
    if (rawContent is! String) {
      return ToolResult.error('参数 content 必须是字符串，收到 ${rawContent.runtimeType}');
    }

    final int bytes = utf8.encode(rawContent).length;
    if (bytes > kMaxWriteBytes) {
      return ToolResult.error(
        '内容有 $bytes 字节，超过单次写入上限 $kMaxWriteBytes 字节。'
        '请分成多个文件，或先写主体再用 edit_file 补充。',
      );
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    // 写入过队列串行化（AGENTS.md §6.2）。
    return MutationQueue.instance.run(
      context.workspace.root,
      () async => _write(target, rawContent, context),
    );
  }

  static Future<ToolResult> _write(
    PathAllowed target,
    String content,
    ToolContext context,
  ) async {
    // 排到队头时用户可能已经点了停止。副作用还没发生，这时退出是干净的。
    if (context.token.isCancelled) return ToolResult.cancelled();

    final File file = File(target.absolute);
    final bool existed = file.existsSync();

    if (existed && file.statSync().type == FileSystemEntityType.directory) {
      return ToolResult.error('${target.relative} 是一个目录，不能当文件写。');
    }

    // 覆盖时沿用原文件的 BOM 和行尾：模型给的 content 一定是 `\n`，
    // 直接写会把一个 CRLF 文件整个改成 LF，diff 里显示每一行都变了。
    TextFileShape shape = TextFileShape(
      content: '',
      hadBom: false,
      newline: Platform.isWindows ? '\r\n' : '\n',
    );
    if (existed) {
      try {
        shape = readTextFile(file);
      } on FormatException {
        // 原文件不是 UTF-8 文本。当新文件写，用平台默认行尾。
      } on FileSystemException catch (e) {
        return ToolResult.error('读取原文件失败：${e.message}');
      }
    }

    try {
      file.parent.createSync(recursive: true);
      file.writeAsBytesSync(shape.encode(content), flush: true);
    } on FileSystemException catch (e) {
      return ToolResult.error('写入失败：${e.message}');
    }

    final int lines = content.isEmpty ? 0 : '\n'.allMatches(content).length + 1;
    return ToolResult.ok(
      existed
          ? '已覆盖 ${target.relative}（$lines 行）。'
          : '已创建 ${target.relative}（$lines 行）。',
      uiPayload: <String, Object?>{
        'path': target.relative,
        'created': !existed,
        'lines': lines,
      },
    );
  }
}
