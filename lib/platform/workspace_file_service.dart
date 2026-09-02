import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:path/path.dart' as p;

import 'workspace_guard.dart';

class WorkspaceFileService {
  const WorkspaceFileService(this.root);

  final String root;

  WorkspaceGuard get _guard => WorkspaceGuard(root);

  Future<String?> createFile(String relativePath, {String content = ''}) async {
    final PathCheck checked = _guard.check(relativePath);
    if (checked is! PathAllowed) return null;
    final File file = File(checked.absolute);
    if (await file.exists()) return null;
    await file.parent.create(recursive: true);
    await file.writeAsString(content, flush: true);
    return checked.relative;
  }

  Future<bool> createDirectory(String relativePath) async {
    final PathCheck checked = _guard.check(relativePath);
    if (checked is! PathAllowed) return false;
    await Directory(checked.absolute).create(recursive: true);
    return true;
  }

  Future<bool> delete(String relativePath) async {
    final PathCheck checked = _guard.check(relativePath);
    if (checked is! PathAllowed) return false;
    final FileSystemEntity entity =
        FileSystemEntity.typeSync(checked.absolute, followLinks: false) ==
            FileSystemEntityType.directory
        ? Directory(checked.absolute)
        : File(checked.absolute);
    if (!await entity.exists()) return false;
    await entity.delete(recursive: entity is Directory);
    return true;
  }

  Future<int> upload() async {
    final List<XFile> picked = await openFiles();
    var count = 0;
    for (final XFile source in picked) {
      final String name = p.basename(source.path);
      final PathCheck checked = _guard.check(name);
      if (checked is! PathAllowed) continue;
      final File target = File(checked.absolute);
      await target.parent.create(recursive: true);
      await target.writeAsBytes(await source.readAsBytes(), flush: true);
      count++;
    }
    return count;
  }

  Future<bool> export(String relativePath) async {
    final PathCheck checked = _guard.check(relativePath);
    if (checked is! PathAllowed) return false;
    final File source = File(checked.absolute);
    if (!await source.exists()) return false;
    final FileSaveLocation? destination = await getSaveLocation(
      suggestedName: p.basename(checked.absolute),
    );
    if (destination == null) return false;
    await source.copy(destination.path);
    return true;
  }
}
