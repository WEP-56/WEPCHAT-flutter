/// 工作区路径安全层（实施 TODO §7-13，AGENTS.md §6.1）。
///
/// 模型给的路径一律先过这里，再交给文件工具。**校验只在这一层做**：
/// 六个文件工具各写一遍等于六份会各自漂移的实现，而漏掉一份的后果是
/// 模型能写到工作区外面去。
///
/// 和 `workspace_paths.dart` 的分工：那边负责"这个会话的目录在哪、把它建
/// 出来"，不看内容；这边负责"模型给的这个路径能不能碰"。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 单次读取回传给模型的字节上限。
///
/// 超出的部分由 `truncateForModel` 截断（§7-6）。定在这里而不是各工具里：
/// 上限是工作区基础设施的属性，不是某个工具的偏好（AGENTS.md §6.1）。
const int kMaxReadBytes = 256 * 1024;

/// 单次写入的字节上限。模型一次吐出超过这个量的正文基本是失控。
const int kMaxWriteBytes = 2 * 1024 * 1024;

/// 路径校验结果。
///
/// 用 sealed class 而不是"可空的 absolute + 可空的 reason"：两个可空字段
/// 能表达出四种组合，其中两种没有意义（AGENTS.md §4）。
sealed class PathCheck {
  const PathCheck();
}

/// 通过校验。
class PathAllowed extends PathCheck {
  const PathAllowed({required this.absolute, required this.relative});

  /// 规范化后的绝对路径，直接拿去做文件操作。
  final String absolute;

  /// 相对工作区根、用 `/` 分隔的路径。
  ///
  /// 回给模型的文本一律用这个，不用 [absolute]：绝对路径里带用户名和真实
  /// 目录结构，属于不该出现在模型上下文里的信息（AGENTS.md §5.1）。
  /// 根目录本身是空串。
  final String relative;
}

/// 未通过校验。
class PathRejected extends PathCheck {
  const PathRejected(this.reason);

  /// 给模型看的说明。要写成它据此能改对的话，不是堆栈。
  final String reason;
}

/// 一个会话工作区的路径守卫。
///
/// 每个会话一个实例（根目录不同），由 `ToolContext` 携带。
class WorkspaceGuard {
  WorkspaceGuard(String root) : root = p.normalize(p.absolute(root));

  /// 规范化后的工作区根目录绝对路径。
  final String root;

  /// [root] 解析掉符号链接之后的样子，惰性求值。
  ///
  /// 根目录自己就可能在链接下面（macOS 的 `/tmp` → `/private/tmp`，
  /// Windows 上的目录联接）。不先把根也解析一遍，符号链接检查会把
  /// 合法路径当成越界。
  String? _realRoot;

  /// 校验模型给的路径。
  ///
  /// [allowRoot] 为 true 时接受工作区根本身（`list_files` 不带 path 就是这
  /// 种情况）；文件类操作留默认 false，避免"把整个目录当文件写"。
  PathCheck check(String raw, {bool allowRoot = false}) {
    final String trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return allowRoot
          ? PathAllowed(absolute: root, relative: '')
          : const PathRejected('path 不能为空');
    }

    if (trimmed.contains('\u0000')) {
      return const PathRejected('path 含有非法的空字符');
    }

    // `\\?\C:\...`（扩展长度前缀）和 `\\server\share`（UNC）绕过规范化，
    // 也绕过下面的包含检查。直接拒，不尝试解释。
    if (trimmed.startsWith(r'\\') || trimmed.startsWith('//')) {
      return const PathRejected('不接受 UNC 路径与 \\\\?\\ 前缀，请给工作区内的相对路径');
    }

    // `join` 遇到绝对的第二段会丢掉前面的部分，所以绝对路径和相对路径
    // 走同一句：模型给绝对路径时由下面的包含检查裁决，不在这里先拒——
    // 它可能只是把 list_files 显示的路径原样抄了回来。
    final String absolute = p.normalize(p.join(root, trimmed));

    final String? badSegment = _firstBadSegment(absolute);
    if (badSegment != null) return PathRejected(badSegment);

    if (p.equals(absolute, root)) {
      return allowRoot
          ? PathAllowed(absolute: root, relative: '')
          : const PathRejected('这是工作区根目录，不是一个文件');
    }

    // 第一道：字面上的包含关系，挡住 `../` 逃逸。
    // `isWithin` 在 Windows 上按大小写不敏感比较，正是这里要的语义。
    if (!p.isWithin(root, absolute)) {
      return PathRejected('路径越出了会话工作区：$trimmed');
    }

    // 第二道：把符号链接解析掉再看一次。字面检查挡不住工作区里指向外面
    // 的链接——那是"路径本身合法、落点不合法"。
    final String? escaped = _symlinkEscape(absolute);
    if (escaped != null) return PathRejected(escaped);

    return PathAllowed(
      absolute: absolute,
      relative: p.relative(absolute, from: root).replaceAll(r'\', '/'),
    );
  }

  /// 逐段检查文件名的合法性，返回第一处问题的说明；都合法则 null。
  ///
  /// 三类检查都是 Windows 的规则，但**在所有平台上一视同仁**：工作区文件
  /// 会在 Android 和 Windows 之间流转，只在 Windows 上拒等于让同一个模型
  /// 调用在两个平台上产生不同结果，也让开发机上的测试测不到真实行为。
  String? _firstBadSegment(String absolute) {
    final String relative = p.relative(absolute, from: root);
    if (relative == '.') return null;

    for (final String segment in p.split(relative)) {
      if (segment.isEmpty || segment == '.' || segment == '..') continue;

      if (_kReservedNames.contains(_stem(segment).toUpperCase())) {
        return '「$segment」是 Windows 保留设备名，换一个文件名';
      }
      final int bad = segment.codeUnits.indexWhere(_isIllegalCodeUnit);
      if (bad >= 0) {
        return '文件名「$segment」含有非法字符 ${_describe(segment.codeUnits[bad])}';
      }
      // Windows 会静默吃掉结尾的空格和点，于是写进去的文件名和模型以为
      // 写的那个不是同一个，下一次 read_file 就找不到了。
      if (segment.endsWith(' ') || segment.endsWith('.')) {
        return '文件名「$segment」不能以空格或点结尾';
      }
    }
    return null;
  }

  /// 解析符号链接后仍在工作区内则返回 null，否则返回拒绝说明。
  String? _symlinkEscape(String absolute) {
    final String realRoot = _resolveRoot();
    final String? real = _resolveDeepestExisting(absolute);
    // 路径整条都还不存在（要新建的文件），没有链接可解析，字面检查已足够。
    if (real == null) return null;
    if (p.equals(real, realRoot) || p.isWithin(realRoot, real)) return null;
    return '路径经符号链接指向了工作区外面：${p.relative(absolute, from: root)}';
  }

  String _resolveRoot() {
    final String? cached = _realRoot;
    if (cached != null) return cached;
    // 根目录还没建出来时解析会抛。那时字面上的根就是最好的近似，
    // 而且此刻工作区里也不可能有链接。
    String resolved;
    try {
      resolved = Directory(root).resolveSymbolicLinksSync();
    } on FileSystemException {
      resolved = root;
    }
    return _realRoot = resolved;
  }

  /// 把 [absolute] 中已经存在的那一段解析掉链接，再接回剩下的部分。
  ///
  /// 不能直接对 [absolute] 调 `resolveSymbolicLinksSync`：待写入的文件通常
  /// 还不存在，那样会抛。返回 null 表示这条路径一级都不存在。
  String? _resolveDeepestExisting(String absolute) {
    String current = absolute;
    final List<String> tail = <String>[];

    while (FileSystemEntity.typeSync(current, followLinks: false) ==
        FileSystemEntityType.notFound) {
      final String parent = p.dirname(current);
      if (parent == current) return null;
      tail.insert(0, p.basename(current));
      current = parent;
    }

    try {
      final String real = Directory(current).resolveSymbolicLinksSync();
      return tail.isEmpty ? real : p.joinAll(<String>[real, ...tail]);
    } on FileSystemException {
      // 竞态：刚才还在，现在没了。当作不存在处理，字面检查已经过了。
      return null;
    }
  }

  /// 文件名里第一个点之前的部分。`NUL.txt` 在 Windows 上一样是设备名。
  static String _stem(String segment) {
    final int dot = segment.indexOf('.');
    return dot < 0 ? segment : segment.substring(0, dot);
  }

  static bool _isIllegalCodeUnit(int unit) {
    if (unit < 0x20) return true; // 控制字符
    return _kIllegalChars.contains(unit);
  }

  static String _describe(int unit) {
    return unit < 0x20
        ? 'U+${unit.toRadixString(16).padLeft(4, '0')}'
        : '「${String.fromCharCode(unit)}」';
  }
}

/// `< > : " | ? *`。反斜杠和正斜杠不在内——它们是分隔符，由 `p.split` 处理。
final Set<int> _kIllegalChars = <int>{0x3C, 0x3E, 0x3A, 0x22, 0x7C, 0x3F, 0x2A};

const Set<String> _kReservedNames = <String>{
  'CON',
  'PRN',
  'AUX',
  'NUL',
  'COM1',
  'COM2',
  'COM3',
  'COM4',
  'COM5',
  'COM6',
  'COM7',
  'COM8',
  'COM9',
  'LPT1',
  'LPT2',
  'LPT3',
  'LPT4',
  'LPT5',
  'LPT6',
  'LPT7',
  'LPT8',
  'LPT9',
};
