import 'package:flutter/widgets.dart';

import 'app/app_bootstrap.dart';
import 'app/wepchat_app.dart';
import 'tools/permission_gate.dart';
import 'ui/chat/permission_dialog.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // navigator key 在这里建、两边共用：权限弹窗要在会话状态创建时就接上
  // （`SessionStore` 一建好就可能被要求执行工具），而那时 `WepChatApp` 还
  // 没有 build。共用一个 key 让两者指向同一个 Navigator。
  final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

  final AppBootstrap bootstrap = await AppBootstrap.init(
    permissionPrompt: (PermissionRequest request) async {
      final BuildContext? context = navigatorKey.currentContext;
      // 没有界面可问就返回 null，权限门按拒绝处理。发生在首帧之前，
      // 那时也不该有工具在跑。
      if (context == null) return null;
      return showPermissionDialog(context, request);
    },
  );

  runApp(WepChatApp(bootstrap: bootstrap, navigatorKey: navigatorKey));
}
