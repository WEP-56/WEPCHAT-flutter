/// 扫描会话工作区目录，生成文件列表。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/workspace.dart';

/// 扫描指定目录，返回文件列表。
///
/// 递归列出全部文件；传入 [includeDirectories] 时也返回目录实体，供
/// 工作区文件树展示空目录。扩展名只决定展示类型，不参与过滤。
/// 失败（目录不存在、权限不足）时返回空列表——工作区是可选功能，读不到不该
/// 拦住会话加载。
Future<List<WorkspaceFile>> scanWorkspaceDirectory(
  String path, {
  bool includeDirectories = false,
}) async {
  try {
    final Directory dir = Directory(path);
    if (!await dir.exists()) return <WorkspaceFile>[];

    final List<WorkspaceFile> files = <WorkspaceFile>[];
    await for (final FileSystemEntity entity in dir.list(recursive: true)) {
      final bool isDirectory = entity is Directory;
      if (entity is! File && !(includeDirectories && isDirectory)) continue;

      final FileStat stat = await entity.stat();
      final String relative = p.relative(entity.path, from: path);

      files.add(
        WorkspaceFile(
          name: relative.replaceAll(r'\', '/'),
          kind: isDirectory ? FileKind.other : fileKindFromName(entity.path),
          size: isDirectory ? '文件夹' : _formatSize(stat.size),
          time: _formatTime(stat.modified),
          isDirectory: isDirectory,
        ),
      );
    }

    // 按修改时间倒序：最新的在前。
    files.sort((WorkspaceFile a, WorkspaceFile b) => b.time.compareTo(a.time));
    return files;
  } on FileSystemException {
    return <WorkspaceFile>[];
  }
}

String _formatSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

String _formatTime(DateTime dt) {
  final String hh = dt.hour.toString().padLeft(2, '0');
  final String mm = dt.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}
