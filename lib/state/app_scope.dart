import 'package:flutter/widgets.dart';

import 'app_settings.dart';
import 'session_store.dart';

/// 向下提供全局状态对象。
///
/// 这里只传递对象引用，不参与重建：需要跟随变化的组件自己用
/// [ListenableBuilder] 订阅，避免一次设置变更重建整棵树。
class AppScope extends InheritedWidget {
  const AppScope({
    super.key,
    required this.settings,
    required this.sessions,
    required super.child,
  });

  final AppSettings settings;
  final SessionStore sessions;

  static AppScope _of(BuildContext context) {
    final AppScope? scope = context
        .dependOnInheritedWidgetOfExactType<AppScope>();
    if (scope == null) {
      throw FlutterError('AppScope 未找到：请确认组件位于 WepChatApp 之下。');
    }
    return scope;
  }

  static AppSettings settingsOf(BuildContext context) => _of(context).settings;

  static SessionStore sessionsOf(BuildContext context) => _of(context).sessions;

  @override
  bool updateShouldNotify(AppScope oldWidget) {
    return settings != oldWidget.settings || sessions != oldWidget.sessions;
  }
}

extension AppScopeX on BuildContext {
  AppSettings get settings => AppScope.settingsOf(this);

  SessionStore get sessions => AppScope.sessionsOf(this);
}
