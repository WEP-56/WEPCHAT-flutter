/// `list_files`：列出工作区文件树（功能协议 §5）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../../ai/provider_api.dart';
import '../../platform/workspace_guard.dart';
import '../tool.dart';
import '../truncate.dart';
import 'tool_args.dart';

/// 一次最多列多少个条目。
///
/// 返回内容必须受数量限制（协议 §5）：一个 `node_modules` 能让单次结果
/// 顶掉整个上下文窗口。
const int _kMaxEntries = 400;

class ListFilesTool extends Tool {
  const ListFilesTool();

  @override
  String get permissionId => 'read_file';

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'list_files',
    description:
        '列出会话工作区里的文件和目录，带类型、大小和修改时间。'
        '不传 path 就列工作区根目录。路径一律是相对工作区根的相对路径。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'path': <String, Object?>{
          'type': 'string',
          'description': '要列的目录，相对工作区根。留空表示根目录。',
        },
        'recursive': <String, Object?>{
          'type': 'boolean',
          'description': '是否递归子目录，默认 true。',
        },
      },
      'required': <String>[],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final ArgReader args = ArgReader(arguments, context);
    final PathAllowed target = args.path(allowMissing: true, allowRoot: true);
    final bool recursive = args.optionalBool('recursive', fallback: true);
    if (args.error != null) return args.error!;

    final String root = target.absolute;

    final Directory dir = Directory(root);
    if (!dir.existsSync()) {
      return ToolResult.error('目录不存在：${displayPath(target.relative)}');
    }

    final List<_Row> rows = <_Row>[];
    bool overflowed = false;

    try {
      await for (final FileSystemEntity entity in dir.list(
        recursive: recursive,
        followLinks: false,
      )) {
        if (context.token.isCancelled) return ToolResult.cancelled();
        if (rows.length >= _kMaxEntries) {
          overflowed = true;
          break;
        }
        final _Row? row = _describe(entity, root);
        if (row != null) rows.add(row);
      }
    } on FileSystemException catch (e) {
      return ToolResult.error('列目录失败：${e.message}');
    }

    if (rows.isEmpty) {
      return ToolResult.ok('${displayPath(target.relative)} 是空目录。');
    }

    // 排序让同一个目录每次列出来顺序一样：目录遍历的原始顺序由文件系统
    // 决定，同一个目录两次调用顺序不同会让模型以为文件动过。
    rows.sort((_Row a, _Row b) => a.path.compareTo(b.path));

    final StringBuffer buf = StringBuffer()
      ..writeln('${displayPath(target.relative)} 下共 ${rows.length} 项：');
    for (final _Row row in rows) {
      buf.writeln(row.line);
    }
    if (overflowed) {
      buf.writeln(
        '[已达 $_kMaxEntries 项上限，还有未列出的内容。'
        '请指定子目录再列一次]',
      );
    }

    return ToolResult.ok(
      truncateForModel(buf.toString()),
      uiPayload: <String, Object?>{
        'count': rows.length,
        'truncated': overflowed,
      },
    );
  }

  /// 符号链接不跟随也不列出。
  ///
  /// 列出来会让模型以为那是工作区里的文件，然后对它发 `read_file`——
  /// 那次调用会被守卫按"经链接指向外面"拒掉，模型收到一条自相矛盾的
  /// 反馈（明明你列给我的）。不列比列了再拒好。
  static _Row? _describe(FileSystemEntity entity, String root) {
    final String rel = p
        .relative(entity.path, from: root)
        .replaceAll(r'\', '/');

    if (entity is Link) return null;
    if (entity is Directory) {
      return _Row(path: rel, line: '  $rel/');
    }
    if (entity is! File) return null;

    final FileStat stat = entity.statSync();
    if (stat.type == FileSystemEntityType.link) return null;

    return _Row(
      path: rel,
      line:
          '  $rel  ${_size(stat.size)}  '
          '${stat.modified.toLocal().toString().substring(0, 16)}',
    );
  }

  static String _size(int bytes) {
    if (bytes < 1024) return '${bytes}B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)}KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)}MB';
  }
}

class _Row {
  const _Row({required this.path, required this.line});

  final String path;
  final String line;
}
