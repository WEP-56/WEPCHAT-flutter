/// 扫描会话工作区目录，生成文件列表。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../models/workspace.dart';

/// 扫描指定目录，返回文件列表。
///
/// 只返回可识别格式的文件（由 `_parseKind` 决定），跳过子目录和未识别扩展名。
/// 失败（目录不存在、权限不足）时返回空列表——工作区是可选功能，读不到不该
/// 拦住会话加载。
Future<List<WorkspaceFile>> scanWorkspaceDirectory(String path) async {
  try {
    final Directory dir = Directory(path);
    if (!await dir.exists()) return <WorkspaceFile>[];

    final List<WorkspaceFile> files = <WorkspaceFile>[];
    await for (final FileSystemEntity entity in dir.list(recursive: true)) {
      if (entity is! File) continue;

      final FileKind? kind = _parseKind(entity.path);
      if (kind == null) continue;

      final FileStat stat = await entity.stat();
      final String relative = p.relative(entity.path, from: path);

      files.add(
        WorkspaceFile(
          name: relative.replaceAll(r'\', '/'),
          kind: kind,
          size: _formatSize(stat.size),
          time: _formatTime(stat.modified),
        ),
      );
    }

    // 按修改时间倒序：最新的在前。
    files.sort((WorkspaceFile a, WorkspaceFile b) =>
        b.time.compareTo(a.time));
    return files;
  } on FileSystemException {
    return <WorkspaceFile>[];
  }
}

FileKind? _parseKind(String path) {
  final String ext = p.extension(path).toLowerCase();
  return switch (ext) {
    '.md' => FileKind.md,
    '.csv' => FileKind.csv,
    '.py' => FileKind.py,
    '.css' => FileKind.css,
    '.png' => FileKind.png,
    '.jpg' || '.jpeg' => FileKind.jpg,
    '.html' || '.htm' => FileKind.html,
    '.json' => FileKind.json,
    '.pdf' => FileKind.pdf,
    '.txt' => FileKind.txt,
    _ => null,
  };
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
