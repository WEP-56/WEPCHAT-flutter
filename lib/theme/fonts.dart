import 'package:flutter/material.dart';

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
