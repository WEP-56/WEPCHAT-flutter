import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App 私有数据目录的解析。平台差异集中在这里（AGENTS.md §7）。
///
/// 两平台的语义（实施 TODO §2 要求验证的点）：
/// - Android：`/data/data/<pkg>/files` 之类的应用私有目录。未 root 拿不到，
///   卸载时随应用删除。
/// - Windows：`%APPDATA%\<publisher>\<app>`，用户可读——这是"API key 存
///   DB 明文在 Windows 上等于明文可读"的原因（实施 TODO §13 第 4 条）。
///
/// 用 `getApplicationSupportDirectory()` 而不是 documents 目录：documents
/// 在 Android 上可能被媒体扫描器索引，也会出现在用户可见的文件管理器里，
/// 而库文件不是用户产物。
class AppPaths {
  const AppPaths._(this.dataRoot);

  /// 私有数据根目录，已确保存在。
  final Directory dataRoot;

  static Future<AppPaths> resolve() async {
    final Directory root = await getApplicationSupportDirectory();
    if (!root.existsSync()) {
      root.createSync(recursive: true);
    }
    return AppPaths._(root);
  }

  /// 用于测试：直接用字符串路径构造。
  factory AppPaths.fromPath(String path) => AppPaths._(Directory(path));

  /// 主库路径（存储设计 §4）。WAL 与 shm 由 SQLite 在同目录自动管理。
  String get databasePath => p.join(dataRoot.path, 'wepchat.db');

  /// 设置文件路径（实施 TODO §13.4）。含明文 API key，所以必须在私有目录里，
  /// 不能放工作区——工作区是用户会拿去分享的地方。
  String get settingsPath => p.join(dataRoot.path, 'settings.json');

  /// 内容寻址的 blob 根目录。
  String get blobRoot => p.join(dataRoot.path, 'blobs');

  /// 工作区根目录的兜底位置：用户没配、或配的路径展开不了时用这里
  /// （见 `WorkspaceRoots.resolve`）。
  String get workspaceRoot => p.join(dataRoot.path, 'workspaces');
}
