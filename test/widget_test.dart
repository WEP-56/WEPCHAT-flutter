import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/app/wepchat_app.dart';

void main() {
  // 这些是布局冒烟测试：只确认两种形态各自能构建出关键区域，
  // 不校验像素，避免把 UI 细节钉死在测试里。
  testWidgets('窄屏只显示聊天区，侧栏收进抽屉', (WidgetTester tester) async {
    await tester.pumpWidget(const WepChatApp());
    await tester.pump();

    expect(find.text('给 WePChat 发消息…'), findsOneWidget);
    // 工作区面板在 endDrawer 里，未打开时不会构建。
    expect(find.text('工作区'), findsNothing);
  });

  testWidgets('宽屏同时显示会话列表、聊天与工作区', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const WepChatApp());
    await tester.pump();

    expect(find.text('WePChat'), findsOneWidget);
    expect(find.text('工作区'), findsOneWidget);
    expect(find.text('给 WePChat 发消息…'), findsOneWidget);
  });

  testWidgets('宽屏可以收起会话列表', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const WepChatApp());
    await tester.pump();

    await tester.tap(find.byTooltip('收起会话列表'));
    await tester.pump();

    expect(find.text('搜索会话'), findsNothing);
    expect(find.byTooltip('展开会话列表'), findsOneWidget);
  });
}
