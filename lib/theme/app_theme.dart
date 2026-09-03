import 'package:flutter/material.dart';

import 'palette.dart';

/// 从语义色板派生 Flutter [ThemeData]。
abstract final class WepTheme {
  static ThemeData build(Brightness brightness, AppAccent accent) {
    final AppPalette palette = brightness == Brightness.dark
        ? AppPalette.dark(accent)
        : AppPalette.light(accent);

    final ColorScheme scheme =
        ColorScheme.fromSeed(
          seedColor: palette.accent,
          brightness: brightness,
        ).copyWith(
          primary: palette.accent,
          surface: palette.bg,
          error: palette.danger,
        );

    final Typography typography = Typography.material2021(
      platform: TargetPlatform.android,
      colorScheme: scheme,
    );
    final TextTheme text =
        (brightness == Brightness.dark ? typography.white : typography.black)
            .apply(
              bodyColor: palette.text1,
              displayColor: palette.text1,
              decorationColor: palette.text2,
            );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      extensions: <ThemeExtension<dynamic>>[palette],
      scaffoldBackgroundColor: palette.bg,
      canvasColor: palette.bg,
      dividerColor: palette.border,
      // 桌面端没有触屏的物理反馈，点击态必须可见；统一在主题层恢复轻量
      // ripple，避免每个按钮各写一套 pressed 状态。
      splashFactory: InkRipple.splashFactory,
      splashColor: palette.active,
      highlightColor: palette.active,
      hoverColor: palette.hover,
      textTheme: text,
      iconTheme: IconThemeData(color: palette.text2, size: 18),
      dividerTheme: DividerThemeData(
        color: palette.border,
        thickness: 1,
        space: 1,
      ),
      tooltipTheme: TooltipThemeData(
        waitDuration: const Duration(milliseconds: 500),
        textStyle: TextStyle(fontSize: 11.5, color: palette.bg),
        decoration: BoxDecoration(
          color: palette.text1,
          borderRadius: BorderRadius.circular(6),
        ),
      ),
      scrollbarTheme: ScrollbarThemeData(
        thickness: const WidgetStatePropertyAll<double>(6),
        radius: const Radius.circular(3),
        thumbColor: WidgetStatePropertyAll<Color>(
          palette.text3.withValues(alpha: 0.45),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      ),
      popupMenuTheme: PopupMenuThemeData(
        color: palette.bgRaise,
        surfaceTintColor: Colors.transparent,
        elevation: 6,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: palette.border),
        ),
        textStyle: TextStyle(fontSize: 12.5, color: palette.text1),
      ),
      drawerTheme: DrawerThemeData(
        backgroundColor: palette.bgSide,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: palette.text1,
        contentTextStyle: TextStyle(fontSize: 12.5, color: palette.bg),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        isDense: true,
        border: InputBorder.none,
        hintStyle: TextStyle(fontSize: 13.5, color: palette.text3),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: FadeUpwardsPageTransitionsBuilder(),
          TargetPlatform.windows: FadeUpwardsPageTransitionsBuilder(),
        },
      ),
    );
  }
}
