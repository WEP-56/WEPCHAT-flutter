import 'package:flutter/material.dart';

/// 应用文字缩放档位。通过根部 `MediaQuery.textScaler` 应用，保证显式字号
/// 和主题字号都能一起调整，而不需要在每个组件里复制一套比例逻辑。
enum AppFontSize {
  small(0.9, '小'),
  medium(1.0, '默认'),
  large(1.15, '大');

  const AppFontSize(this.scale, this.label);

  final double scale;
  final String label;
}

/// 等宽字体的统一入口。
///
/// 原型里直接写 `fontFamily: 'monospace'`，该名字在 Windows 上解析不到，
/// 会退化成默认无衬线字体。这里集中声明回退链，UI 只调用 [AppFonts.mono]。
abstract final class AppFonts {
  /// Android 上 `monospace` 有效；Windows 上依次尝试 Consolas / Cascadia Mono。
  static const List<String> monoFallback = <String>[
    'Consolas',
    'Cascadia Mono',
    'Courier New',
    'monospace',
    'Roboto Mono',
    'Menlo',
  ];

  static TextStyle mono({
    required double size,
    required Color color,
    FontWeight? weight,
    double? height,
    TextDecoration? decoration,
  }) {
    return TextStyle(
      fontFamily: monoFallback.first,
      fontFamilyFallback: monoFallback.sublist(1),
      fontSize: size,
      color: color,
      fontWeight: weight,
      height: height,
      decoration: decoration,
    );
  }
}
