import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/settings/settings_screen.dart';
import '../ui/viewers/file_viewer_screen.dart';
import '../ui/viewers/html_preview_screen.dart';
import '../ui/viewers/image_viewer_screen.dart';

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

  static void openHtml(BuildContext context, {required String file}) {
    _push(context, HtmlPreviewScreen(file: file));
  }

  static void _push(BuildContext context, Widget page) {
    unawaited(
      Navigator.of(
        context,
      ).push<void>(MaterialPageRoute<void>(builder: (BuildContext _) => page)),
    );
  }
}
