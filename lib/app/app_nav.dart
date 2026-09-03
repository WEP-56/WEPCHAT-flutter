import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/settings/settings_screen.dart';
import '../ui/viewers/file_viewer_screen.dart';
import '../ui/viewers/html_viewer_screen.dart';
import '../ui/viewers/image_viewer_screen.dart';
import '../platform/workspace_guard.dart';
import '../state/app_scope.dart';
import '../ui/widgets/toast.dart';

/// 全屏页面导航的唯一入口。
///
/// 统一走 [Navigator]，而不是在外壳里用状态切换内容区：这样 Android 的系统
/// 返回键、Windows 的返回按钮和路由栈行为都只有一套实现。
abstract final class AppNav {
  static void openSettings(BuildContext context, {String? sectionId}) {
    _push(context, SettingsScreen(initialSectionId: sectionId));
  }

  static void openFile(BuildContext context, {required String file}) {
    _push(context, FileViewerScreen(file: file));
  }

  static void openImage(
    BuildContext context, {
    required String file,
    required List<String> gallery,
  }) {
    _push(context, ImageViewerScreen(file: file, gallery: gallery));
  }

  /// 打开当前会话里的 HTML 文件。
  ///
  /// Android、Windows 统一使用应用内预览，支持预览与源码双模式切换。
  static Future<void> openHtml(
    BuildContext context, {
    required String file,
  }) async {
    final String workspace = context.sessions.workspacePathFor(
      context.sessions.active.id,
    );
    final PathCheck checked = WorkspaceGuard(workspace).check(file);
    if (checked is! PathAllowed) {
      if (context.mounted && checked is PathRejected) {
        showAppToast(context, checked.reason);
      }
      return;
    }

    if (!context.mounted) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => HtmlViewerScreen(filePath: checked.absolute),
      ),
    );
  }

  static void _push(BuildContext context, Widget page) {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => page)),
    );
  }
}
