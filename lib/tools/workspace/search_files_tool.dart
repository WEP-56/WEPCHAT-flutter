/// `search_files`：在工作区里搜文本（功能协议 §5）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../ai/provider_api.dart';
import '../../platform/workspace_guard.dart';
import '../tool.dart';
import '../truncate.dart';
import 'text_file.dart';
import 'tool_args.dart';

/// 命中数上限的默认值与硬上限。
const int _kDefaultMaxMatches = 50;
const int _kHardMaxMatches = 200;

/// 单个文件超过这个大小就跳过。
///
/// 搜索要扫全部文件，逐个读进内存不设限的话，工作区里一个几百 MB 的日志
/// 就能把进程撑爆。这个值比 `kMaxReadBytes` 小：读是用户点名要的一个文件，
/// 搜是碰上什么读什么。
const int _kMaxScanBytes = 1024 * 1024;

class SearchFilesTool extends Tool {
  const SearchFilesTool();

  @override
  String get permissionId => 'read_file';

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'search_files',
        description:
            '在会话工作区的文本文件里搜索内容，返回文件路径、行号和命中行。'
            '只搜文本文件，自动跳过图片、压缩包等二进制文件。',
        schema: <String, Object?>{
          'type': 'object',
          'properties': <String, Object?>{
            'query': <String, Object?>{
              'type': 'string',
              'description': '要搜的文本；use_regex 为 true 时是正则表达式。',
            },
            'path': <String, Object?>{
              'type': 'string',
              'description': '可选，限定搜索的子目录。留空搜整个工作区。',
            },
            'glob': <String, Object?>{
              'type': 'string',
              'description': r'可选文件名过滤，如 "*.md"、"**/*.dart"。',
            },
            'use_regex': <String, Object?>{
              'type': 'boolean',
              'description': '把 query 当正则处理，默认 false。',
            },
            'max_matches': <String, Object?>{
              'type': 'integer',
              'description': '最多返回多少条命中，默认 50。',
            },
          },
          'required': <String>['query'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final ArgReader args = ArgReader(arguments, context);
    final String query = args.requireString('query');
    final PathAllowed target = args.path(allowMissing: true, allowRoot: true);
    final String? glob = args.optionalString('glob');
    final bool useRegex = args.optionalBool('use_regex', fallback: false);
    final int maxMatches = args.optionalPositiveInt(
      'max_matches',
      fallback: _kDefaultMaxMatches,
      max: _kHardMaxMatches,
    );
    if (args.error != null) return args.error!;

    final RegExp pattern;
    try {
      pattern = useRegex
          ? RegExp(query)
          : RegExp(RegExp.escape(query), caseSensitive: false);
    } on FormatException catch (e) {
      return ToolResult.error('正则表达式不合法：${e.message}');
    }

    final Directory dir = Directory(target.absolute);
    if (!dir.existsSync()) {
      return ToolResult.error('目录不存在：${displayPath(target.relative)}');
    }

    final RegExp? nameFilter = glob == null ? null : _globToRegExp(glob);
    final List<String> hits = <String>[];
    int scanned = 0;
    bool overflowed = false;

    try {
      await for (final FileSystemEntity entity
          in dir.list(recursive: true, followLinks: false)) {
        if (context.token.isCancelled) return ToolResult.cancelled();
        if (hits.length >= maxMatches) {
          overflowed = true;
          break;
        }
        if (entity is! File) continue;

        final String rel =
            p.relative(entity.path, from: context.workspace.root)
                .replaceAll(r'\', '/');
        if (nameFilter != null && !nameFilter.hasMatch(rel)) continue;

        final List<String>? found =
            _scan(entity, rel, pattern, maxMatches - hits.length);
        if (found == null) continue; // 二进制、太大、读不了。
        scanned++;
        hits.addAll(found);
      }
    } on FileSystemException catch (e) {
      return ToolResult.error('搜索失败：${e.message}');
    }

    if (hits.isEmpty) {
      return ToolResult.ok(
        '在 ${displayPath(target.relative)} 下的 $scanned 个文本文件里'
        '没有找到「$query」。',
      );
    }

    final StringBuffer buf = StringBuffer()
      ..writeln('找到 ${hits.length} 条命中：');
    for (final String hit in hits) {
      buf.writeln(hit);
    }
    if (overflowed) {
      buf.writeln('[已达 $maxMatches 条上限，可能还有更多。缩小 path 或 glob 再搜]');
    }

    return ToolResult.ok(
      truncateForModel(buf.toString()),
      uiPayload: <String, Object?>{
        'query': query,
        'matches': hits.length,
        'truncated': overflowed,
      },
    );
  }

  /// 扫一个文件。返回 null 表示这个文件不参与搜索（二进制 / 太大 / 读不了）。
  static List<String>? _scan(
    File file,
    String relative,
    RegExp pattern,
    int budget,
  ) {
    final List<int> bytes;
    try {
      if (file.lengthSync() > _kMaxScanBytes) return null;
      bytes = file.readAsBytesSync();
    } on FileSystemException {
      // 权限不足或读的瞬间被删。跳过一个文件不该让整次搜索失败。
      return null;
    }
    if (looksBinary(bytes)) return null;

    final String text;
    try {
      text = utf8.decode(stripBom(bytes));
    } on FormatException {
      return null; // 不是 UTF-8，按二进制处理。
    }

    final List<String> out = <String>[];
    final List<String> lines = const LineSplitter().convert(text);
    for (int i = 0; i < lines.length && out.length < budget; i++) {
      if (!pattern.hasMatch(lines[i])) continue;
      // 命中行本身可能很长（压缩过的 JS 是一整行）。截短到能看出上下文
      // 即可，要全文模型会去 read_file。
      final String line = lines[i].trim();
      final String brief = line.length <= 160 ? line : '${line.substring(0, 160)}…';
      out.add('  $relative:${i + 1}: $brief');
    }
    return out;
  }

  /// 把 glob 翻成正则。
  ///
  /// 只支持 `*`、`**`、`?` 三个通配符——协议里给的例子就这些
  /// （`**/*.md`）。字符类、花括号展开等留到真有人要的时候再说。
  static RegExp _globToRegExp(String glob) {
    final StringBuffer buf = StringBuffer('^');
    for (int i = 0; i < glob.length; i++) {
      final String c = glob[i];
      if (c == '*') {
        if (i + 1 < glob.length && glob[i + 1] == '*') {
          buf.write('.*');
          i++;
          // `**/` 也要能匹配零层目录：`**/*.md` 应当命中根下的 a.md。
          if (i + 1 < glob.length && glob[i + 1] == '/') i++;
        } else {
          buf.write('[^/]*');
        }
      } else if (c == '?') {
        buf.write('[^/]');
      } else {
        buf.write(RegExp.escape(c));
      }
    }
    buf.write(r'$');
    return RegExp(buf.toString(), caseSensitive: false);
  }
}
