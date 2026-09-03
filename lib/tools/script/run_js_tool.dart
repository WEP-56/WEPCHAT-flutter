/// `run_js`: bounded JavaScript with an application-owned workspace bridge.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../ai/provider_api.dart';
import '../../core/cancellation_token.dart';
import '../../platform/workspace_guard.dart';
import '../../runtime/wep_js_runtime.dart';
import '../tool.dart';
import '../truncate.dart';
import '../workspace/text_file.dart';
import '../workspace/write_file_tool.dart';

const int _maxScriptBytes = 512 * 1024;
const int _maxListedFiles = 500;

class RunJsTool extends Tool {
  const RunJsTool({WepJsRuntime runtime = const FjsWepJsRuntime()})
    : _runtime = runtime;

  final WepJsRuntime _runtime;

  @override
  ToolDefinition get definition => const ToolDefinition(
    name: 'run_js',
    description:
        '在隔离的 JavaScript 运行时中处理文本、JSON、CSV 和工作区文件。'
        '工作区 API：await wep.fs.listFiles(path?, recursive?)、readText(path)、writeText(path, content)。'
        '可使用 fetch 做网络连通性/API 调试；不能访问 Shell、进程、环境变量或工作区外路径。'
        '脚本中的密钥会随调用记录保存，不要把长期凭据写入脚本。',
    schema: <String, Object?>{
      'type': 'object',
      'properties': <String, Object?>{
        'code': <String, Object?>{
          'type': 'string',
          'description': '要执行的 JavaScript 源码。',
        },
        'timeout_ms': <String, Object?>{
          'type': 'integer',
          'description': '超时毫秒数，默认 12000，允许 1000-30000。',
        },
      },
      'required': <String>['code'],
    },
  );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final Object? rawCode = arguments['code'];
    if (rawCode is! String || rawCode.trim().isEmpty) {
      return ToolResult.error('参数 code 必须是非空字符串');
    }
    if (utf8.encode(rawCode).length > _maxScriptBytes) {
      return ToolResult.error('脚本超过 $_maxScriptBytes 字节上限');
    }

    final Object? rawTimeout = arguments['timeout_ms'];
    final int timeoutMs = rawTimeout == null
        ? kJsExecutionTimeout.inMilliseconds
        : rawTimeout is int
        ? rawTimeout
        : -1;
    if (timeoutMs < 1000 || timeoutMs > 30000) {
      return ToolResult.error('参数 timeout_ms 必须是 1000-30000 之间的整数');
    }

    final List<String> written = <String>[];
    try {
      final JsExecutionResult result = await _runtime.run(
        code: rawCode,
        token: context.token,
        timeout: Duration(milliseconds: timeoutMs),
        bridge: (Map<String, Object?> request) =>
            _bridge(request, context, written),
      );
      final String value = formatJsValue(result.value);
      final String logs = result.logs.join('\n');
      final String content = logs.isEmpty ? value : '$logs\n$value';
      return ToolResult.ok(
        truncateForModel(content),
        uiPayload: <String, Object?>{
          if (written.isNotEmpty) 'paths': List<String>.of(written),
          'outputChars': content.length,
        },
      );
    } on JsExecutionTimedOut {
      return ToolResult.error('JavaScript 执行超过 ${timeoutMs}ms，已中断');
    } on CancelledException {
      return ToolResult.cancelled('JavaScript 执行已中断');
    } on Object catch (e) {
      return ToolResult.error('JavaScript 执行失败：$e');
    }
  }

  Future<Object?> _bridge(
    Map<String, Object?> request,
    ToolContext context,
    List<String> written,
  ) async {
    final Object? rawAction = request['action'];
    if (rawAction is! String) throw ArgumentError('缺少 bridge action');
    return switch (rawAction) {
      'listFiles' => _listFiles(request, context),
      'readText' => _readText(request, context),
      'writeText' => _writeText(request, context, written),
      _ => throw ArgumentError('不支持的 bridge action：$rawAction'),
    };
  }

  Future<List<Map<String, Object?>>> _listFiles(
    Map<String, Object?> request,
    ToolContext context,
  ) async {
    final Object? rawPath = request['path'];
    if (rawPath != null && rawPath is! String) {
      throw ArgumentError('path 必须是字符串');
    }
    final Object? rawRecursive = request['recursive'];
    if (rawRecursive != null && rawRecursive is! bool) {
      throw ArgumentError('recursive 必须是布尔值');
    }
    final String path = rawPath as String? ?? '';
    final bool recursive = rawRecursive as bool? ?? true;
    final PathCheck checked = context.workspace.check(path, allowRoot: true);
    if (checked is! PathAllowed) {
      throw ArgumentError((checked as PathRejected).reason);
    }
    final Directory root = Directory(checked.absolute);
    if (!await root.exists()) throw ArgumentError('目录不存在：${checked.relative}');
    final List<Map<String, Object?>> out = <Map<String, Object?>>[];
    await for (final FileSystemEntity entity in root.list(
      recursive: recursive,
      followLinks: false,
    )) {
      context.token.throwIfCancelled();
      if (out.length >= _maxListedFiles) break;
      final String relative = p.relative(
        entity.path,
        from: context.workspace.root,
      );
      final FileStat stat = await entity.stat();
      out.add(<String, Object?>{
        'path': relative.replaceAll(r'\', '/'),
        'type': stat.type == FileSystemEntityType.directory
            ? 'directory'
            : 'file',
        'size': stat.size,
      });
    }
    return out;
  }

  Future<String> _readText(
    Map<String, Object?> request,
    ToolContext context,
  ) async {
    final Object? rawPath = request['path'];
    if (rawPath is! String || rawPath.trim().isEmpty) {
      throw ArgumentError('path 必须是非空字符串');
    }
    final PathCheck checked = context.workspace.check(rawPath);
    if (checked is! PathAllowed) {
      throw ArgumentError((checked as PathRejected).reason);
    }
    final File file = File(checked.absolute);
    if (!await file.exists()) throw ArgumentError('文件不存在：${checked.relative}');
    if ((await file.length()) > kMaxReadBytes) {
      throw ArgumentError('文件超过 $kMaxReadBytes 字节读取上限');
    }
    return readTextFile(file).content;
  }

  Future<String> _writeText(
    Map<String, Object?> request,
    ToolContext context,
    List<String> written,
  ) async {
    final Object? rawPath = request['path'];
    final Object? rawContent = request['content'];
    if (rawPath is! String || rawPath.trim().isEmpty) {
      throw ArgumentError('path 必须是非空字符串');
    }
    if (rawContent is! String) throw ArgumentError('content 必须是字符串');
    final ToolResult result = await WriteFileTool().execute(<String, Object?>{
      'path': rawPath,
      'content': rawContent,
    }, context);
    if (result.outcome != ToolOutcome.ok) throw ArgumentError(result.content);
    final Object? uiPath = result.uiPayload?['path'];
    if (uiPath is String && !written.contains(uiPath)) written.add(uiPath);
    return uiPath is String ? uiPath : rawPath;
  }
}
