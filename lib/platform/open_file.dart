/// 使用系统默认应用打开工作区文件。
library;

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

/// 打开一个已经完成路径校验的本地文件。
///
/// Windows 由用户的默认应用处理 `.html` / `.htm` 等文件；调用方负责在
/// 进入这里之前完成工作区边界校验，避免把任意本地路径交给系统。
Future<bool> openFileInDefaultApp(String path) async {
  final File file = File(path);
  if (!await file.exists()) return false;

  try {
    if (Platform.isAndroid) {
      return await const MethodChannel('com.wep.wepchat/platform').invokeMethod<bool>(
            'openFile',
            <String, Object?>{'path': path, 'mimeType': _mimeType(path)},
          ) ??
          false;
    }
    return await launchUrl(
      Uri.file(path),
      mode: LaunchMode.externalApplication,
    );
  } on Object {
    return false;
  }
}

String _mimeType(String path) {
  final String ext = path.toLowerCase().split('.').last;
  return <String, String>{
    'apk': 'application/vnd.android.package-archive',
    'pdf': 'application/pdf',
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'zip': 'application/zip',
    'txt': 'text/plain',
    'html': 'text/html',
  }[ext] ?? 'application/octet-stream';
}
