import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/platform/workspace_guard.dart';
import 'package:wepchat/tools/tool.dart';

/// 文件工具测试的共用底座。
///
/// 用真临时目录而不是内存文件系统：这些工具的行为**就是**文件系统行为
/// （符号链接、BOM、行尾、权限），换成假的等于测了另一个东西。
class ToolHarness {
  ToolHarness._(this._temp, this._outside)
    : context = ToolContext(
        sessionId: 'session-test',
        workspace: WorkspaceGuard(_temp.path),
        token: CancellationToken.none,
      );

  factory ToolHarness.create() {
    return ToolHarness._(
      Directory.systemTemp.createTempSync('wep_tool_'),
      Directory.systemTemp.createTempSync('wep_outside_'),
    );
  }

  final Directory _temp;

  /// 工作区**外**的目录，用来验证越界确实被挡住。
  final Directory _outside;

  final ToolContext context;

  String get root => context.workspace.root;

  /// 一个已经取消的 context，验证工具在关键点检查中断（§7-4）。
  ToolContext cancelledContext() {
    final CancellationTokenSource source = CancellationTokenSource()..cancel();
    return ToolContext(
      sessionId: context.sessionId,
      workspace: context.workspace,
      token: source.token,
    );
  }

  void write(String relative, String content) {
    final File file = File(p.join(_temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(content);
  }

  void writeBytes(String relative, List<int> bytes) {
    final File file = File(p.join(_temp.path, relative));
    file.parent.createSync(recursive: true);
    file.writeAsBytesSync(bytes);
  }

  String read(String relative) =>
      File(p.join(_temp.path, relative)).readAsStringSync();

  List<int> readBytes(String relative) =>
      File(p.join(_temp.path, relative)).readAsBytesSync();

  bool exists(String relative) =>
      File(p.join(_temp.path, relative)).existsSync();

  /// 工作区外一个路径。
  String outsidePath(String name) => p.join(_outside.path, name);

  /// 在工作区里建一个指向 [target] 的链接。
  ///
  /// 返回 false 表示这个平台建不了（Windows 上非管理员建不了目录链接）——
  /// 调用方据此跳过，而不是假装通过。
  bool linkTo(String target, String linkName) {
    try {
      Link(p.join(_temp.path, linkName)).createSync(target);
      return true;
    } on FileSystemException {
      return false;
    }
  }

  void dispose() {
    for (final Directory dir in <Directory>[_temp, _outside]) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }
  }
}
