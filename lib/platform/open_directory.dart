/// 打开文件管理器并定位到指定目录。
library;

import 'dart:io';

import 'package:url_launcher/url_launcher.dart';

/// 在文件管理器中打开指定目录。
///
/// Windows: 用 `file:///` 协议打开文件夹
/// Android: 使用 ACTION_VIEW intent（url_launcher 会处理）
/// 其他平台: 同样通过 url_launcher
Future<bool> openDirectoryInExplorer(String path) async {
  final Directory dir = Directory(path);
  if (!await dir.exists()) return false;

  try {
    final Uri uri = Uri.file(path);
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}
