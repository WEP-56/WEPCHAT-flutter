import 'dart:io';

import 'package:file_selector/file_selector.dart';

/// 工作区根目录选择能力集中在平台适配层。
///
/// Android 当前不允许修改工作区根目录，避免把应用私有目录、SAF 权限和
/// 会话工作区迁移混在设置页里；Windows 使用系统目录选择器。
bool get supportsWorkspaceRootSelection => !Platform.isAndroid;

Future<String?> pickWorkspaceRoot(String initialDirectory) async {
  if (!supportsWorkspaceRootSelection) return null;
  return getDirectoryPath(initialDirectory: initialDirectory);
}
