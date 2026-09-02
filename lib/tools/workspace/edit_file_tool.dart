/// `edit_file`：精确替换文件里的一段文本（功能协议 §5，实施 TODO §7-14）。
///
/// 照 pi 的做法：BOM 剥离、行尾探测与还原（都在 `text_file.dart`）、
/// **匹配不到就报错绝不猜**、写入过 mutation 队列串行化。
library;

import 'dart:io';

import '../../ai/provider_api.dart';
import '../../platform/workspace_guard.dart';
import '../tool.dart';
import 'mutation_queue.dart';
import 'text_file.dart';
import 'tool_args.dart';

class EditFileTool extends Tool {
  const EditFileTool();

  @override
  String get permissionId => 'write_file';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'edit_file',
    description:
        '把文件里的一段文本替换成另一段。调用前先用 read_file 看清原文。'
        'find 必须和文件里的内容逐字一致（含缩进），匹配不到会报错而不会'
        '猜测位置。默认要求 find 在文件里只出现一次；确实要改全部时'
        '把 all 设成 true。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'path': <String, Object?>{
          'type': 'string',
          'description': '文件路径，相对工作区根。',
        },
        'find': <String, Object?>{
          'type': 'string',
          'description': '要被替换的原文，逐字一致。',
        },
        'replace': <String, Object?>{
          'type': 'string',
          'description': '替换成的新文本。空串表示删掉这一段。',
        },
        'all': <String, Object?>{
          'type': 'boolean',
          'description': '替换全部出现处，默认 false（只替换唯一的那处）。',
        },
      },
      'required': <String>['path', 'find', 'replace'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final ArgReader args = ArgReader(arguments, context);
    final PathAllowed target = args.path();
    final String find = args.requireString('find');
    final bool all = args.optionalBool('all', fallback: false);
    if (args.error != null) return args.error!;

    // replace 允许空串（"删掉这一段"），所以不走 requireString。
    final Object? rawReplace = arguments['replace'];
    if (rawReplace == null) return ToolResult.error('缺少必填参数 replace');
    if (rawReplace is! String) {
      return ToolResult.error('参数 replace 必须是字符串，收到 ${rawReplace.runtimeType}');
    }

    if (find == rawReplace) {
      return ToolResult.error('find 和 replace 完全相同，这次编辑不会有任何改动。');
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    return MutationQueue.instance.run(
      context.workspace.root,
      () async => _edit(target, find, rawReplace, all, context),
    );
  }

  static Future<ToolResult> _edit(
    PathAllowed target,
    String find,
    String replace,
    bool all,
    ToolContext context,
  ) async {
    if (context.token.isCancelled) return ToolResult.cancelled();

    final File file = File(target.absolute);
    if (!file.existsSync()) {
      return ToolResult.error('文件不存在：${target.relative}。新建文件请用 write_file。');
    }

    final TextFileShape shape;
    try {
      shape = readTextFile(file);
    } on FormatException {
      return ToolResult.error('${target.relative} 不是 UTF-8 文本，无法编辑。');
    } on FileSystemException catch (e) {
      return ToolResult.error('读取失败：${e.message}');
    }

    // 模型给的 find 一定用 `\n`；文件正文已经在 readTextFile 里统一成
    // `\n` 了，所以这里直接比。写回时 shape.encode 还原原来的行尾。
    final String needle = find.replaceAll('\r\n', '\n');
    final int count = _countOccurrences(shape.content, needle);

    if (count == 0) {
      return ToolResult.error(
        '在 ${target.relative} 里找不到 find 指定的内容，没有做任何修改。'
        '**不要猜测位置重试**：先 read_file 看清原文（注意缩进和空格），'
        '再用逐字一致的 find。',
      );
    }
    if (count > 1 && !all) {
      return ToolResult.error(
        'find 在 ${target.relative} 里出现了 $count 次，无法确定改哪一处。'
        '请把 find 写得更长以包含唯一的上下文；确实要全改就设 all=true。',
      );
    }

    final String updated = all
        ? shape.content.replaceAll(needle, replace.replaceAll('\r\n', '\n'))
        : shape.content.replaceFirst(needle, replace.replaceAll('\r\n', '\n'));

    try {
      file.writeAsBytesSync(shape.encode(updated), flush: true);
    } on FileSystemException catch (e) {
      return ToolResult.error('写入失败：${e.message}');
    }

    return ToolResult.ok(
      '已修改 ${target.relative}，替换了 ${all ? count : 1} 处。',
      uiPayload: <String, Object?>{
        'path': target.relative,
        'replacements': all ? count : 1,
        'find': find,
        'replace': replace,
      },
    );
  }

  /// 不重叠地数出现次数。
  ///
  /// 不用 `allMatches`：那要先把 find 转成正则，而模型给的 find 里带
  /// 正则元字符（`.`、`(`、`$`）是常态，转义一步漏掉就变成了模式匹配。
  static int _countOccurrences(String haystack, String needle) {
    if (needle.isEmpty) return 0;
    int count = 0;
    int from = 0;
    while (true) {
      final int at = haystack.indexOf(needle, from);
      if (at < 0) return count;
      count++;
      from = at + needle.length;
    }
  }
}
