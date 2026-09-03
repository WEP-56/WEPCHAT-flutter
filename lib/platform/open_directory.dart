/// 打开文件管理器并定位到指定目录。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

const MethodChannel _directoryChannel = MethodChannel(
  'com.wep.wepchat/platform',
);

/// 在文件管理器中打开指定目录。
///
/// Windows: 用 `file:///` 协议打开文件夹。
/// Android: 通过宿主原生桥接，使用 `FileProvider` 提供安全的 content URI
/// 并发送 ACTION_VIEW intent。
/// 其他平台: 同样通过 url_launcher。
Future<bool> openDirectoryInExplorer(String path) async {
  final Directory dir = Directory(path);
  if (!await dir.exists()) return false;

  try {
    if (Platform.isAndroid) {
      return await _directoryChannel.invokeMethod<bool>(
            'openDirectory',
            <String, Object?>{'path': dir.path},
          ) ??
          false;
    }

    final Uri uri = Uri.file(path);
    return await launchUrl(uri, mode: LaunchMode.externalApplication);
  } on Object {
    return false;
  }
}
