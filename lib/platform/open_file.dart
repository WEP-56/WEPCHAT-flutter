/// 使用系统默认应用打开工作区文件。
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

import 'file_save_result.dart';

/// 打开一个已经完成路径校验的本地文件。
///
/// Windows 由用户的默认应用处理 `.html` / `.htm` 等文件；调用方负责在
/// 进入这里之前完成工作区边界校验，避免把任意本地路径交给系统。
Future<bool> openFileInDefaultApp(String path) async {
  final File file = File(path);
  if (!await file.exists()) return false;

  try {
    if (Platform.isAndroid) {
      return await const MethodChannel(
            'com.wep.wepchat/platform',
          ).invokeMethod<bool>('openFile', <String, Object?>{
            'path': path,
            'mimeType': _mimeType(path),
          }) ??
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

/// 调起系统分享面板。Android 使用 FileProvider，桌面端回退为系统打开。
Future<bool> shareFile(String path) async {
  final File file = File(path);
  if (!await file.exists()) return false;
  if (Platform.isAndroid) {
    return await const MethodChannel(
          'com.wep.wepchat/platform',
        ).invokeMethod<bool>('shareFile', <String, Object?>{
          'path': path,
          'mimeType': _mimeType(path),
        }) ??
        false;
  }
  return openFileInDefaultApp(path);
}

/// 保存已校验的本地文件：Android 写公共目录，桌面选择目标位置。
/// Android 不调用 file_selector 的保存选择器，该平台没有实现此功能。
Future<FileSaveResult> saveFileToDevice(String path) async {
  try {
    final File file = File(path);
    if (!await file.exists()) return const FileSaveFailed('导出失败：文件不存在');
    if (defaultTargetPlatform == TargetPlatform.android) {
      final String mime = _mimeType(path);
      final bool? saved = await const MethodChannel('com.wep.wepchat/platform')
          .invokeMethod<bool>('saveFile', <String, Object?>{
            'path': path,
            'mimeType': mime,
          });
      if (saved != true) return const FileSaveFailed('导出失败：系统未确认文件保存完成');
      return FileSaved(
        mime.startsWith('image/')
            ? '已保存到 Pictures/WePChat，可在相册中查看'
            : '已保存到 Download/WePChat',
      );
    }
    if (!<TargetPlatform>{
      TargetPlatform.windows,
      TargetPlatform.linux,
      TargetPlatform.macOS,
    }.contains(defaultTargetPlatform)) {
      return const FileSaveFailed('当前平台不支持文件导出');
    }
    final FileSaveLocation? destination = await getSaveLocation(
      suggestedName: p.basename(path),
    );
    if (destination == null) return const FileSaveCancelled();
    if (await File(destination.path).exists() &&
        await FileSystemEntity.identical(path, destination.path)) {
      return const FileSaveFailed('请选择与工作区原文件不同的保存位置');
    }
    await file.copy(destination.path);
    return FileSaved('已导出 ${p.basename(path)}');
  } on MissingPluginException {
    return const FileSaveFailed('文件保存组件未加载，请重新构建并安装应用');
  } on PlatformException catch (error) {
    return FileSaveFailed(switch (error.code) {
      'UNSUPPORTED_VERSION' => '保存到公共目录需要 Android 10 或更高版本',
      'FILE_NOT_FOUND' => '导出失败：源文件不存在',
      'SAVE_DENIED' => '导出失败：系统拒绝写入目标目录',
      _ => '导出失败：系统无法保存文件，请检查剩余空间和存储权限',
    });
  } on FileSystemException {
    return const FileSaveFailed('导出失败：无法读写文件，请检查剩余空间和目录权限');
  } on UnimplementedError {
    return const FileSaveFailed('当前平台尚未实现文件保存选择器');
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
        'gif': 'image/gif',
        'webp': 'image/webp',
        'bmp': 'image/bmp',
        'zip': 'application/zip',
        'txt': 'text/plain',
        'html': 'text/html',
        'htm': 'text/html',
        'css': 'text/css',
        'scss': 'text/x-scss',
        'js': 'text/javascript',
        'ts': 'text/typescript',
        'tsx': 'text/typescript',
        'jsx': 'text/javascript',
        'py': 'text/x-python',
        'json': 'application/json',
        'csv': 'text/csv',
        'md': 'text/markdown',
        'yaml': 'text/yaml',
        'yml': 'text/yaml',
        'xml': 'application/xml',
      }[ext] ??
      'application/octet-stream';
}
