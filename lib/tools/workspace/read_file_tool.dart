/// `read_file`：读取工作区里的文本文件（功能协议 §5）。
library;

import 'dart:convert';
import 'dart:io';

import '../../ai/provider_api.dart';
import '../../platform/workspace_guard.dart';
import '../tool.dart';
import '../truncate.dart';
import 'text_file.dart';
import 'tool_args.dart';

class ReadFileTool extends Tool {
  const ReadFileTool();

  @override
  String get permissionId => 'read_file';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'read_file',
    description:
        '读取工作区里一个文本文件的内容，返回带行号的正文。'
        '大文件会被截断，用 lines 指定行范围（如 "1-80"、"120-"）分段读。'
        '不能读图片、压缩包等二进制文件。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'path': <String, Object?>{
          'type': 'string',
          'description': '文件路径，相对工作区根。',
        },
        'lines': <String, Object?>{
          'type': 'string',
          'description': '可选行范围，如 "1-80"、"120-"、"45"。行号从 1 起。',
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
    final String? range = args.optionalString('lines');
    if (args.error != null) return args.error!;

    final File file = File(target.absolute);
    if (!file.existsSync()) {
      return ToolResult.error('文件不存在：${target.relative}');
    }

    final int size = file.lengthSync();
    if (size > kMaxReadBytes) {
      return ToolResult.error(
        '文件 ${target.relative} 有 $size 字节，超过单次读取上限 '
        '$kMaxReadBytes 字节。这个工具只读文本文件；'
        '如果确实是文本，请用 lines 分段读。',
      );
    }

    final List<int> bytes;
    try {
      bytes = file.readAsBytesSync();
    } on FileSystemException catch (e) {
      return ToolResult.error('读取失败：${e.message}');
    }

    if (looksBinary(bytes)) {
      return ToolResult.error('${target.relative} 看起来是二进制文件，这个工具只读文本。');
    }

    final String text;
    try {
      text = utf8.decode(stripBom(bytes));
    } on FormatException {
      return ToolResult.error('${target.relative} 不是有效的 UTF-8 文本，无法读取。');
    }

    if (context.token.isCancelled) return ToolResult.cancelled();

    final List<String> lines = const LineSplitter().convert(text);
    final _Range? window = range == null
        ? null
        : _Range.parse(range, lines.length);
    if (range != null && window == null) {
      return ToolResult.error('lines 格式不对：$range。用 "1-80"、"120-" 或 "45"。');
    }

    final int from = window?.from ?? 1;
    final int to = window?.to ?? lines.length;
    if (from > lines.length) {
      return ToolResult.error(
        '${target.relative} 只有 ${lines.length} 行，读不到第 $from 行。',
      );
    }

    final StringBuffer buf = StringBuffer();
    final int width = to.toString().length;
    for (int i = from; i <= to && i <= lines.length; i++) {
      buf.writeln('${i.toString().padLeft(width)}\t${lines[i - 1]}');
    }

    final String header = window == null
        ? '${target.relative}（共 ${lines.length} 行）：'
        : '${target.relative} 第 $from–$to 行（共 ${lines.length} 行）：';

    return ToolResult.ok(
      '$header\n${truncateForModel(buf.toString())}',
      uiPayload: <String, Object?>{
        'path': target.relative,
        'totalLines': lines.length,
        'from': from,
        'to': to > lines.length ? lines.length : to,
      },
    );
  }
}

/// 行范围。行号从 1 起、闭区间——和 `read_file` 输出里的行号一致，
/// 模型才能照着结果里看到的行号回头再读。
class _Range {
  const _Range(this.from, this.to);

  final int from;
  final int to;

  /// `"12"` / `"12-40"` / `"12-"` / `"-40"`。解析不出来返回 null。
  static _Range? parse(String raw, int totalLines) {
    final String text = raw.trim();
    final Match? m = RegExp(r'^(\d*)\s*-\s*(\d*)$').firstMatch(text);

    if (m == null) {
      final int? single = int.tryParse(text);
      if (single == null || single <= 0) return null;
      return _Range(single, single);
    }

    final String head = m.group(1)!;
    final String tail = m.group(2)!;
    if (head.isEmpty && tail.isEmpty) return null;

    final int from = head.isEmpty ? 1 : int.parse(head);
    final int to = tail.isEmpty ? totalLines : int.parse(tail);
    if (from <= 0 || to < from) return null;
    return _Range(from, to);
  }
}
