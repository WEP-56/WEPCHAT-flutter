import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import '../browser/browser_page.dart';
import '../ui/settings/settings_screen.dart';
import '../ui/viewers/file_viewer_screen.dart';
import '../ui/viewers/image_viewer_screen.dart';
import '../platform/open_file.dart';
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
  /// Android 使用应用内浏览器，Windows 遵循用户的默认浏览器；同时避免把
  /// 未校验的相对路径直接交给 `file:` URI。
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

    if (Platform.isAndroid) {
      if (!context.mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(filePath: checked.absolute),
        ),
      );
      return;
    }

    final bool opened = await openFileInDefaultApp(
      p.normalize(checked.absolute),
    );
    if (!opened && context.mounted) {
      showAppToast(context, '无法用系统浏览器打开文件');
    }
  }

  static void _push(BuildContext context, Widget page) {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => page)),
    );
  }
}
