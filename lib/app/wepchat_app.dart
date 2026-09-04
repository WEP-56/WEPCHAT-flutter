import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../state/app_scope.dart';
import '../state/app_settings.dart';
import '../state/session_store.dart';
import '../theme/app_theme.dart';
import '../theme/fonts.dart';
import '../theme/palette.dart';
import '../ui/shell/desktop_shell_controller.dart';
import '../ui/shell/app_shell.dart';
import '../ui/shell/window_title_bar.dart';
import 'app_bootstrap.dart';
import 'app_nav.dart';
import 'update_service.dart';
import '../ui/update_dialog.dart';

/// 应用根组件：持有全局状态对象，构建主题与外壳。
class WepChatApp extends StatefulWidget {
  const WepChatApp({required this.bootstrap, this.navigatorKey, super.key});

  final AppBootstrap bootstrap;

  /// 由 `main()` 传进来，和权限弹窗共用同一个 Navigator。
  /// 测试不传，自己建一个。
  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<WepChatApp> createState() => _WepChatAppState();
}

class _WepChatAppState extends State<WepChatApp> {
  // 两者都由 bootstrap 创建：会话列表要在首帧之前装载完
  // （见 `AppBootstrap.init`），设置对象要和它一起交给同一个 scope。
  AppSettings get _settings => widget.bootstrap.settings;
  SessionStore get _sessions => widget.bootstrap.sessions;

  final DesktopShellController _desktopShell = DesktopShellController();
  late final GlobalKey<NavigatorState> _navigatorKey =
      widget.navigatorKey ?? GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_checkForUpdateOnStartup());
    });
  }

  @override
  void dispose() {
    _desktopShell.dispose();
    // settings / sessions / storage 归 bootstrap，由它按相反顺序拆。
    widget.bootstrap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      settings: _settings,
      sessions: _sessions,
      child: _AppearanceBuilder(settings: _settings, builder: _buildApp),
    );
  }

  Widget _buildApp(
    BuildContext context,
    ThemeMode mode,
    AppAccent accent,
    AppFontSize fontSize,
  ) {
    final ThemeData light = WepTheme.build(Brightness.light, accent);
    final ThemeData dark = WepTheme.build(Brightness.dark, accent);

    return MaterialApp(
      title: 'WePChat',
      debugShowCheckedModeBanner: false,
      navigatorKey: _navigatorKey,
      theme: light,
      darkTheme: dark,
      themeMode: mode,
      // builder 位于 Navigator 之上，所以自定义标题栏对全屏路由同样有效。
      builder: (BuildContext context, Widget? child) {
        if (child == null) {
          throw StateError('MaterialApp.builder 没有收到子树');
        }
        final Brightness brightness = switch (mode) {
          ThemeMode.system => MediaQuery.platformBrightnessOf(context),
          ThemeMode.light => Brightness.light,
          ThemeMode.dark => Brightness.dark,
        };
        final ThemeData resolved = brightness == Brightness.dark ? dark : light;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          // 移动端状态栏图标跟随主题；桌面端忽略这项设置。
          value:
              (brightness == Brightness.dark
                      ? SystemUiOverlayStyle.light
                      : SystemUiOverlayStyle.dark)
                  .copyWith(
                    statusBarColor: Colors.transparent,
                    systemNavigationBarColor: Colors.transparent,
                  ),
          child: MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(fontSize.scale)),
            child: WindowFrame(
              palette: resolved.extension<AppPalette>()!,
              shellController: _desktopShell,
              onNewSession: () =>
                  _sessions.createSession(model: _settings.defaultModelKey),
              onOpenSettings: _openSettings,
              child: child,
            ),
          ),
        );
      },
      home: AppShell(desktopController: _desktopShell),
    );
  }

  void _openSettings() {
    final BuildContext? context = _navigatorKey.currentContext;
    if (context == null) {
      throw StateError('桌面标题栏无法访问 Navigator');
    }
    AppNav.openSettings(context);
  }

  Future<void> _checkForUpdateOnStartup() async {
    if (!_settings.autoCheckUpdates) return;

    try {
      final PackageInfo info = await PackageInfo.fromPlatform();
      final UpdateService service = UpdateService();
      final UpdateCheckResult result;
      try {
        result = await service.check(info.version);
      } finally {
        service.dispose();
      }

      if (!mounted || !result.hasUpdate) return;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final BuildContext? context = _navigatorKey.currentContext;
        if (context != null) {
          unawaited(showReleaseUpdateDialog(context, result.release!));
        }
      });
    } on Object {
      // 启动时检查必须静默失败，不能打断用户进入应用。
      return;
    }
  }
}

/// 只在外观设置变化时重建 [MaterialApp]。
///
/// 直接用 `ListenableBuilder(listenable: settings)` 会让温度滑杆这类高频设置
/// 每帧重建整棵树，所以这里自己比对外观字段。
class _AppearanceBuilder extends StatefulWidget {
  const _AppearanceBuilder({required this.settings, required this.builder});

  final AppSettings settings;
  final Widget Function(
    BuildContext context,
    ThemeMode mode,
    AppAccent accent,
    AppFontSize fontSize,
  )
  builder;

  @override
  State<_AppearanceBuilder> createState() => _AppearanceBuilderState();
}

class _AppearanceBuilderState extends State<_AppearanceBuilder> {
  late ThemeMode _mode = widget.settings.themeMode;
  late AppAccent _accent = widget.settings.accent;
  late AppFontSize _fontSize = widget.settings.fontSize;

  @override
  void initState() {
    super.initState();
    widget.settings.addListener(_onSettingsChanged);
  }

  @override
  void dispose() {
    widget.settings.removeListener(_onSettingsChanged);
    super.dispose();
  }

  void _onSettingsChanged() {
    final ThemeMode mode = widget.settings.themeMode;
    final AppAccent accent = widget.settings.accent;
    final AppFontSize fontSize = widget.settings.fontSize;
    if (mode == _mode && accent == _accent && fontSize == _fontSize) return;
    setState(() {
      _mode = mode;
      _accent = accent;
      _fontSize = fontSize;
    });
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(context, _mode, _accent, _fontSize);
  }
}
