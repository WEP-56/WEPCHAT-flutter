import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/platform/mcp_windows_stdio.dart';

void main() {
  test('只继承必要的系统变量，显式环境变量覆盖大小写不同的键', () {
    final Map<String, String> environment = mcpProcessEnvironment(
      <String, String>{
        'Path': 'system-path',
        'SYSTEMROOT': 'windows',
        'OPENAI_API_KEY': 'private',
      },
      <String, String>{'PATH': 'configured-path', 'TOKEN': 'explicit'},
    );
    expect(environment, <String, String>{
      'SYSTEMROOT': 'windows',
      'PATH': 'configured-path',
      'TOKEN': 'explicit',
    });
  });

  test('npx 包装脚本转换为 Node CLI，保留空格、中文与 shell 字符参数', () async {
    final Directory root = await Directory.systemTemp.createTemp(
      'wepchat_mcp_',
    );
    try {
      final Directory bin = await Directory(p.join(root.path, '带 空格')).create();
      final File cli = File(
        p.join(bin.path, 'node_modules', 'npm', 'bin', 'npx-cli.js'),
      );
      await cli.parent.create(recursive: true);
      await cli.writeAsString('');
      await File(p.join(bin.path, 'npx.cmd')).writeAsString('');
      await File(p.join(bin.path, 'node.exe')).writeAsString('');
      const List<String> args = <String>[
        '-y',
        'example-server',
        'A & B',
        '中文路径',
      ];
      final McpLaunchCommand command = await resolveMcpLaunch(
        'npx',
        args,
        <String, String>{'PATH': bin.path},
        root.path,
      );
      expect(command.executable, p.join(bin.path, 'node.exe'));
      expect(command.arguments, <String>[cli.path, ...args]);
    } finally {
      await root.delete(recursive: true);
    }
  });

  test('找不到可执行文件会报可诊断错误，不偷偷改成 shell 执行', () async {
    await expectLater(
      resolveMcpLaunch(
        'missing-wepchat-mcp-command',
        const <String>[],
        const <String, String>{},
        null,
      ),
      throwsA(isA<McpFailure>()),
    );
  });
}
