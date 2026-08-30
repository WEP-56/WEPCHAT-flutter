import 'package:flutter/material.dart';

import '../../theme/palette.dart';

enum IconActionTone { normal, active, danger }

/// 顶栏 / 工具条上的方形图标按钮。
class IconAction extends StatelessWidget {
  const IconAction({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.size = 17,
    this.box = 32,
    this.tone = IconActionTone.normal,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final double size;
  final double box;
  final IconActionTone tone;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final Color color = switch (tone) {
      IconActionTone.normal => palette.text2,
      IconActionTone.active => palette.accent,
      IconActionTone.danger => palette.danger,
    };

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: palette.hover,
        child: SizedBox(
          width: box,
          height: box,
          child: Center(
            child: Icon(icon, size: size, color: color),
          ),
        ),
      ),
    );
  }
}

enum PillTone { neutral, good, warn, danger, accent }

/// 状态标签。
class Pill extends StatelessWidget {
  const Pill(this.label, {super.key, this.tone = PillTone.neutral, this.icon});

  final String label;
  final PillTone tone;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final (Color fg, Color bg) = switch (tone) {
      PillTone.neutral => (palette.text2, palette.bgRaise),
      PillTone.good => (palette.good, palette.goodSoft),
      PillTone.warn => (palette.warn, palette.warnSoft),
      PillTone.danger => (
        palette.danger,
        palette.danger.withValues(alpha: 0.14),
      ),
      PillTone.accent => (palette.accent, palette.accentSoft),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 11, color: fg),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// 分区标题（设置页、面板内部使用）。
class SectionLabel extends StatelessWidget {
  const SectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.4,
        color: context.palette.text3,
      ),
    );
  }
}
