/// 会话工作区目录的解析与创建（功能协议 §2.1，实施 TODO §7-1）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

/// 工作区根目录。
///
/// 每个会话在根下有一个自己的目录，目录名是 `session_id`——不是标题：
/// 标题会被改名、会重复、还可能含路径非法字符，拿它当目录名等于把会话的
/// 文件和一个可变字段绑在一起（功能协议 §2.1）。
class WorkspaceRoots {
  const WorkspaceRoots(this.root);

  /// 已展开成绝对路径的根目录。
  final String root;

  /// 把用户配置的根目录展开成绝对路径。
  ///
  /// 设置里默认是 `~/WePChat/workspaces`。`~` 只有 shell 会展开，Dart 不会，
  /// 直接拿去 `Directory()` 会在 CWD 下建一个真的叫 `~` 的目录。所以这里
  /// 显式换成用户主目录；拿不到主目录（少见，但容器里会）就退到 [fallback]。
  static WorkspaceRoots resolve(String configured, {required String fallback}) {
    final String trimmed = configured.trim();
    if (trimmed.isEmpty) return WorkspaceRoots(fallback);

    String path = trimmed;
    if (path == '~' || path.startsWith('~/') || path.startsWith(r'~\')) {
      final String? home = _homeDir();
      if (home == null) return WorkspaceRoots(fallback);
      path = path.length <= 2 ? home : p.join(home, path.substring(2));
    }

    return WorkspaceRoots(p.normalize(p.absolute(path)));
  }

  static String? _homeDir() {
    final Map<String, String> env = Platform.environment;
    final String? home = Platform.isWindows
        ? env['USERPROFILE'] ?? env['HOME']
        : env['HOME'];
    return (home == null || home.isEmpty) ? null : home;
  }

  /// 某个会话的工作区目录路径。不碰磁盘。
  String pathFor(String sessionId) => p.join(root, sessionId);

  /// 建好某个会话的工作区目录，返回它的路径。
  ///
  /// 幂等：目录已存在就什么都不做。建不出来不抛——工作区是给工具用的，
  /// 建目录失败不该拦住"新建会话"这个纯本地操作；等工具真去写文件时
  /// 再报错，那时用户才有上下文知道问题出在哪。
  ///
  /// 同步而不是异步：建一个目录是微秒级的操作，换成 `Future` 就得在
  /// 新建会话的链路上多一个 await——而这条链路会在 widget 测试的假时间轴里
  /// 跑，真 I/O 的 future 在那里推不动，测试会直接挂住。
  String ensureSession(String sessionId) {
    final String path = pathFor(sessionId);
    try {
      final Directory dir = Directory(path);
      if (!dir.existsSync()) dir.createSync(recursive: true);
    } on FileSystemException {
      // 交给后续的文件工具报错。
    }
    return path;
  }
}
