/// 六个文件工具共用的参数读取与路径解析（实施 TODO §7-1、§7-2）。
///
/// 第一版**不写通用 schema 校验器**（§7-2）：每个工具就两三个字段，手写
/// 检查比写一个校验器再用它检查六个工具更短也更好读。这里只放真正重复的
/// 两件事——按类型取参数、把路径过守卫。
library;

import '../../platform/workspace_guard.dart';
import '../tool.dart';

/// 按类型取参数，把第一处错误攒起来。
///
/// 用累积器而不是每个参数都 `if (bad != null) return bad;`：三个参数就要写
/// 三遍同样的三行。调用方取完所有参数后检查一次 [error] 即可——取错的那次
/// 返回的是占位值，但那之后的代码根本不会执行。
///
/// 只记**第一处**错误：模型一次只改一个地方，报一串错反而让它无从下手。
class ArgReader {
  ArgReader(this._args, this._context);

  final Map<String, Object?> _args;
  final ToolContext _context;

  /// 第一处参数错误；全部合法则为 null。
  ToolResult? error;

  void _fail(String message) => error ??= ToolResult.error(message);

  /// 必填字符串。空串按缺失处理——模型传 `path: ""` 和不传是同一种错。
  String requireString(String key) {
    final Object? raw = _args[key];
    if (raw == null) {
      _fail('缺少必填参数 $key');
      return '';
    }
    if (raw is! String) {
      _fail('参数 $key 必须是字符串，收到 ${raw.runtimeType}');
      return '';
    }
    if (raw.isEmpty) {
      _fail('参数 $key 不能为空');
      return '';
    }
    return raw;
  }

  /// 可选字符串。缺失或空串返回 null。
  String? optionalString(String key) {
    final Object? raw = _args[key];
    if (raw == null) return null;
    if (raw is! String) {
      _fail('参数 $key 必须是字符串，收到 ${raw.runtimeType}');
      return null;
    }
    return raw.trim().isEmpty ? null : raw;
  }

  /// 可选布尔。
  ///
  /// 容忍 `"true"` / `"false"` 字符串：模型把布尔写成字符串是实测见过的
  /// 错法，而它的意图毫无歧义（§7-1 说容错要等真见到再加——这一条见到过）。
  /// 别的类型不猜，直接报错。
  bool optionalBool(String key, {required bool fallback}) {
    final Object? raw = _args[key];
    if (raw == null) return fallback;
    if (raw is bool) return raw;
    if (raw is String) {
      final String lower = raw.trim().toLowerCase();
      if (lower == 'true') return true;
      if (lower == 'false') return false;
    }
    _fail('参数 $key 必须是布尔值，收到 $raw');
    return fallback;
  }

  /// 可选正整数，超出 [max] 时夹到 [max]（模型常写 `max_matches: 100000`，
  /// 那不是错，只是它不知道上限）。
  int optionalPositiveInt(
    String key, {
    required int fallback,
    required int max,
  }) {
    final Object? raw = _args[key];
    if (raw == null) return fallback;
    final int? value = switch (raw) {
      final int i => i,
      final String s => int.tryParse(s.trim()),
      _ => null,
    };
    if (value == null) {
      _fail('参数 $key 必须是整数，收到 $raw');
      return fallback;
    }
    if (value <= 0) {
      _fail('参数 $key 必须大于 0，收到 $value');
      return fallback;
    }
    return value > max ? max : value;
  }

  /// 取路径参数并过一遍守卫。
  ///
  /// 出错时记进 [error] 并返回工作区根作占位——调用方在下一行就 return 了，
  /// 占位值不会被用到。这样六个工具都只需要一次错误检查，而不是"参数错
  /// 检一次、路径错再检一次"。
  ///
  /// [allowMissing] 为 true 时缺参数就走工作区根（`list_files` 不带 path
  /// 是列整个工作区）。越界、保留名、符号链接逃逸的判断**全部**在
  /// `WorkspaceGuard` 里，这里只做转接（§7-13、AGENTS.md §6.1）。
  PathAllowed path({
    String key = 'path',
    bool allowMissing = false,
    bool allowRoot = false,
  }) {
    final PathAllowed atRoot = PathAllowed(
      absolute: _context.workspace.root,
      relative: '',
    );

    final Object? raw = _args[key];
    if (raw == null || (raw is String && raw.trim().isEmpty)) {
      if (!allowMissing) _fail('缺少必填参数 $key');
      return atRoot;
    }
    if (raw is! String) {
      _fail('参数 $key 必须是字符串，收到 ${raw.runtimeType}');
      return atRoot;
    }

    switch (_context.workspace.check(raw, allowRoot: allowRoot)) {
      case final PathAllowed allowed:
        return allowed;
      case PathRejected(:final String reason):
        _fail(reason);
        return atRoot;
    }
  }
}

/// 工作区内的显示路径。根目录显示成 `.`，别的显示相对路径。
String displayPath(String relative) => relative.isEmpty ? '.' : relative;
