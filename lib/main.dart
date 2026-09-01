import 'package:flutter/widgets.dart';

import 'app/app_bootstrap.dart';
import 'app/wepchat_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final AppBootstrap bootstrap = await AppBootstrap.init();
  runApp(WepChatApp(bootstrap: bootstrap));
}
