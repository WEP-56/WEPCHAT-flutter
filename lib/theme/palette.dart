import 'package:flutter/material.dart';

/// 强调色方案。颜色会派生出整套语义色板。
enum AppAccent {
  x(Color(0xFF1D9BF0), 'X 蓝'),
  telegram(Color(0xFF2AABEE), 'Telegram 蓝'),
  violet(Color(0xFF8B5CF6), '紫罗兰'),
  green(Color(0xFF10A37F), '薄荷绿'),
  orange(Color(0xFFF97316), '活力橙');

  const AppAccent(this.color, this.label);

  final Color color;
  final String label;
}

/// 语义化颜色令牌。
///
/// 这是全工程唯一的颜色来源：UI 代码只允许通过 `context.palette` 取色，
/// 不允许在组件里硬编码 `Color(0x...)`，否则浅色 / 深色两套主题会漂移。
@immutable
class AppPalette extends ThemeExtension<AppPalette> {
  const AppPalette({
    required this.brightness,
    required this.accentKind,
    required this.bg,
    required this.bgSide,
    required this.bgSettings,
    required this.bgPanel,
    required this.bgRaise,
    required this.bgRaise2,
    required this.bgComposer,
    required this.border,
    required this.borderStrong,
    required this.text1,
    required this.text2,
    required this.text3,
    required this.accent,
    required this.accentSoft,
    required this.good,
    required this.goodSoft,
    required this.warn,
    required this.warnSoft,
    required this.danger,
    required this.codeBg,
    required this.codeKeyword,
    required this.codeString,
    required this.hover,
    required this.active,
  });

  final Brightness brightness;
  final AppAccent accentKind;

  /// 背景层：聊天窗口 / 侧栏 / 设置页 / 面板 / 抬升块 / 输入区。
  final Color bg, bgSide, bgSettings, bgPanel, bgRaise, bgRaise2, bgComposer;

  /// 描边。
  final Color border, borderStrong;

  /// 文字：主 / 次 / 弱。
  final Color text1, text2, text3;

  /// 状态色与其低透明度底色。
  final Color accent, accentSoft, good, goodSoft, warn, warnSoft, danger;

  /// 代码块配色。
  final Color codeBg, codeKeyword, codeString;

  /// 交互态叠加色。
  final Color hover, active;

  factory AppPalette.light(AppAccent accent) => AppPalette(
    brightness: Brightness.light,
    accentKind: accent,
    // 冷灰纸质感：降低大面积纯白带来的刺眼感，同时保留足够层次。
    bg: const Color(0xFFF7F8FA),
    bgSide: const Color(0xFFF1F2F4),
    bgSettings: const Color(0xFFF4F5F7),
    bgPanel: const Color(0xFFFAFAFB),
    bgRaise: const Color(0xFFECEFF2),
    bgRaise2: const Color(0xFFE3E7EB),
    bgComposer: const Color(0xFFF1F3F5),
    border: const Color(0xFFE1E4E8),
    borderStrong: const Color(0xFFD2D7DD),
    text1: const Color(0xFF0D0D0D),
    text2: const Color(0xFF666666),
    text3: const Color(0xFF8E8E8E),
    accent: accent.color,
    accentSoft: accent.color.withValues(alpha: 0.12),
    good: const Color(0xFF10A37F),
    goodSoft: const Color(0xFF10A37F).withValues(alpha: 0.12),
    warn: const Color(0xFFD97706),
    warnSoft: const Color(0xFFD97706).withValues(alpha: 0.12),
    danger: const Color(0xFFEF4444),
    codeBg: const Color(0xFFF1F3F5),
    codeKeyword: const Color(0xFF8250DF),
    codeString: const Color(0xFF0A7B4B),
    hover: const Color(0x0D000000),
    active: const Color(0x14000000),
  );

  factory AppPalette.dark(AppAccent accent) => AppPalette(
    brightness: Brightness.dark,
    accentKind: accent,
    bg: const Color(0xFF212121),
    bgSide: const Color(0xFF171717),
    bgSettings: const Color(0xFF212121),
    bgPanel: const Color(0xFF171717),
    bgRaise: const Color(0xFF2F2F2F),
    bgRaise2: const Color(0xFF3A3A3A),
    bgComposer: const Color(0xFF2F2F2F),
    border: const Color(0xFF2F2F2F),
    borderStrong: const Color(0xFF404040),
    text1: const Color(0xFFECECEC),
    text2: const Color(0xFFB4B4B4),
    text3: const Color(0xFF8F8F8F),
    accent: accent.color,
    accentSoft: accent.color.withValues(alpha: 0.18),
    good: const Color(0xFF10A37F),
    goodSoft: const Color(0xFF10A37F).withValues(alpha: 0.18),
    warn: const Color(0xFFD97706),
    warnSoft: const Color(0xFFD97706).withValues(alpha: 0.18),
    danger: const Color(0xFFEF4444),
    codeBg: const Color(0xFF171717),
    codeKeyword: const Color(0xFFC792EA),
    codeString: const Color(0xFF9ECBFF),
    hover: const Color(0x0DFFFFFF),
    active: const Color(0x1AFFFFFF),
  );

  /// 主题切换是离散的（浅色 / 深色 / 两种强调色），不需要逐令牌插值。
  @override
  AppPalette copyWith() => this;

  @override
  AppPalette lerp(ThemeExtension<AppPalette>? other, double t) {
    if (other is! AppPalette) return this;
    return t < 0.5 ? this : other;
  }
}

extension AppPaletteX on BuildContext {
  AppPalette get palette => Theme.of(this).extension<AppPalette>()!;
}
