import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/mcp/mcp_config.dart';
import 'package:wepchat/mcp/mcp_connection.dart';
import 'package:wepchat/mcp/mcp_session.dart';
import 'package:wepchat/state/app_settings.dart';
import 'package:wepchat/state/mcp_controller.dart';

import '../mcp/mcp_test_support.dart';

void main() {
  late AppSettings settings;
  late List<FakeMcpConnection> created;
  late McpController controller;

  setUp(() {
    settings = AppSettings.memory();
    created = <FakeMcpConnection>[];
    controller = McpController(
      settings: settings,
      supportsStdio: false,
      factory: (McpServerConfig server, String? workspace) {
        final FakeMcpConnection connection = FakeMcpConnection();
        created.add(connection);
        return connection;
      },
    );
  });
  tearDown(() async {
    await controller.close();
    controller.dispose();
    settings.dispose();
  });

  test('关闭时不会创建连接，允许预先保存配置', () async {
    settings.saveMcpServer(remoteServer());
    final McpSession session = await controller.openSession(
      CancellationToken.none,
    );
    expect(created, isEmpty);
    expect(session.tools, isEmpty);
    await session.close();
  });

  test('每轮连接独立，关闭幂等，配置变更撤销旧绑定', () async {
    settings.saveMcpServer(remoteServer());
    settings.setMcpEnabled(true);
    final McpSession first = await controller.openSession(
      CancellationToken.none,
    );
    final McpSession second = await controller.openSession(
      CancellationToken.none,
    );
    expect(created.length, 2);
    settings.setMcpEnabled(false);
    expect(first.tools.single.token.isCancelled, isTrue);
    expect(second.tools.single.token.isCancelled, isTrue);
    await first.close();
    await second.close();
    await first.close();
    expect(created.map((FakeMcpConnection c) => c.closes), <int>[1, 1]);
  });

  test('Android 在创建进程前拒绝 stdio 配置', () async {
    settings.saveMcpServer(
      McpServerConfig(
        id: 'local',
        name: 'local',
        endpoint: McpStdioEndpoint(command: 'npx'),
      ),
    );
    settings.setMcpEnabled(true);
    await expectLater(
      controller.openSession(CancellationToken.none),
      throwsA(isA<McpFailure>()),
    );
    expect(created, isEmpty);
  });

  test('发现失败会关闭已创建的全部连接，不返回残缺工具集', () async {
    await controller.close();
    controller.dispose();
    controller = McpController(
      settings: settings,
      factory: (McpServerConfig server, String? root) {
        final FakeMcpConnection connection = FakeMcpConnection();
        if (server.id == 'server-b') {
          connection.onConnect = (_) async =>
              throw const McpFailure('discovery failed');
        }
        created.add(connection);
        return connection;
      },
    );
    settings.saveMcpServer(remoteServer());
    settings.saveMcpServer(remoteServer(id: 'server-b'));
    settings.setMcpEnabled(true);
    await expectLater(
      controller.openSession(CancellationToken.none),
      throwsA(isA<McpFailure>()),
    );
    expect(created.map((FakeMcpConnection c) => c.closes), <int>[1, 1]);
  });

  test('连接期间取消会结束等待并释放连接', () async {
    await controller.close();
    controller.dispose();
    final Completer<void> started = Completer<void>();
    final FakeMcpConnection connection = FakeMcpConnection()
      ..onConnect = (CancellationToken token) async {
        started.complete();
        await token.whenCancelled;
        token.throwIfCancelled();
        return <McpToolInfo>[];
      };
    controller = McpController(
      settings: settings,
      factory: (_, _) => connection,
    );
    settings.saveMcpServer(remoteServer());
    settings.setMcpEnabled(true);
    final CancellationTokenSource source = CancellationTokenSource();
    final Future<void> expectation = expectLater(
      controller.openSession(source.token),
      throwsA(isA<CancelledException>()),
    );
    await started.future;
    source.cancel();
    await expectation;
    expect(connection.closes, 1);
  });
}
