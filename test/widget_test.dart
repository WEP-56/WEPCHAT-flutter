import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/app/app_bootstrap.dart';
import 'package:wepchat/app/wepchat_app.dart';

void main() {
  // 这些是布局冒烟测试：只确认两种形态各自能构建出关键区域，
  // 不校验像素，避免把 UI 细节钉死在测试里。
  //
  // 接真存储之后，构建 app 需要一个 bootstrap。每个用例开一个临时目录
  // 当数据根，互不干扰。`WepChatApp.dispose` 会连带关掉 bootstrap，
  // 所以这里只负责删目录。
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('wepchat_widget_');
  });

  // 目录删除放在 tearDown：它比 addTearDown 晚跑，所以下面那次拆存储
  // 一定已经完成，句柄已经松开。
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  /// 构建 app 并等异步初始化落地。返回的 bootstrap 要交给 [disposeApp]。
  Future<AppBootstrap> pumpApp(WidgetTester tester) async {
    // 建存储必须在 runAsync 里：DB isolate 的 ReceivePort 监听回调绑在创建它
    // 的 zone 上。在 widget 测试默认的假时间轴里建，回调就绑到假 zone，
    // 端口消息回来也不会被派发，任何等它的 await 都永久挂住。
    // 在真时间轴里建好，后面关闭时 runAsync 才推得动。
    final AppBootstrap bootstrap = (await tester.runAsync(
      () => AppBootstrap.init(rootOverride: root.path),
    ))!;
    await tester.pumpWidget(WepChatApp(bootstrap: bootstrap));
    await tester.pump();
    return bootstrap;
  }

  /// 拆掉 app 并等存储真的松开文件句柄。
  ///
  /// 必须在用例体里调、必须走 [WidgetTester.runAsync]：关存储要等 DB isolate
  /// 真的退出，而 widget 测试默认跑在假时间轴上，假时钟推不动真 I/O。
  /// 放 `addTearDown` 里不行——那时 binding 已经结束了这个用例，`runAsync`
  /// 不再驱动任何东西，await 会一直挂到用例超时。
  Future<void> disposeApp(WidgetTester tester, AppBootstrap bootstrap) async {
    // 顺序要紧：先在 runAsync 里关，再拆 widget 树。
    //
    // `dispose()` 幂等靠缓存 future，而 future 的续体绑在创建它的 zone 上。
    // 要是先 pump 走 widget，`WepChatApp.dispose` 会在假时间轴里建出这个
    // future，假时钟不推进它就永不完成，随后 await 同一个缓存 future 必挂。
    // 先在真时间轴里建好并跑完，widget 那次拿到的就是已完成的 future。
    await tester.runAsync(() => bootstrap.dispose());
    await tester.pumpWidget(const SizedBox.shrink());
  }

  testWidgets('窄屏只显示聊天区，侧栏收进抽屉', (WidgetTester tester) async {
    final AppBootstrap bootstrap = await pumpApp(tester);

    expect(find.text('给 WePChat 发消息…'), findsOneWidget);
    // 工作区面板在 endDrawer 里，未打开时不会构建。
    expect(find.text('工作区'), findsNothing);

    await disposeApp(tester, bootstrap);
  });

  testWidgets('宽屏同时显示会话列表、聊天与工作区', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppBootstrap bootstrap = await pumpApp(tester);

    expect(find.text('WePChat'), findsOneWidget);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('给 WePChat 发消息…'), findsOneWidget);

    await disposeApp(tester, bootstrap);
  });

  testWidgets('宽屏可以收起会话列表', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final AppBootstrap bootstrap = await pumpApp(tester);

    await tester.tap(find.byTooltip('收起会话列表'));
    await tester.pump();

    expect(find.text('搜索会话'), findsNothing);
    expect(find.byTooltip('展开会话列表'), findsOneWidget);

    await disposeApp(tester, bootstrap);
  });
}
