import 'package:flutter/material.dart';

import '../../app/responsive.dart';
import '../../theme/palette.dart';

/// 设置页的分组卡片。
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.title,
    this.subtitle,
    required this.children,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: palette.bgPanel,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.text1,
            ),
          ),
          if (subtitle != null) ...<Widget>[
            const SizedBox(height: 3),
            Text(
              subtitle!,
              style: TextStyle(
                fontSize: 11.5,
                color: palette.text3,
                height: 1.5,
              ),
            ),
          ],
          const SizedBox(height: 4),
          ...children,
        ],
      ),
    );
  }
}

/// 「标题 + 说明 + 控件」一行。窄屏下控件换到下一行，避免挤压。
class SettingsRow extends StatelessWidget {
  const SettingsRow({
    super.key,
    required this.title,
    this.desc,
    this.leading,
    required this.trailing,
  });

  final String title;
  final String? desc;
  final Widget? leading;
  final Widget trailing;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final Widget label = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w500,
            color: palette.text1,
          ),
        ),
        if (desc != null) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            desc!,
            style: TextStyle(fontSize: 11, color: palette.text3, height: 1.45),
          ),
        ],
      ],
    );

    final Widget labelRow = leading == null
        ? label
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Padding(padding: const EdgeInsets.only(top: 1), child: leading),
              const SizedBox(width: 8),
              Expanded(child: label),
            ],
          );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: isCompact(context)
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                labelRow,
                const SizedBox(height: 8),
                Align(alignment: Alignment.centerLeft, child: trailing),
              ],
            )
          : Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: <Widget>[
                Expanded(child: labelRow),
                const SizedBox(width: 12),
                trailing,
              ],
            ),
    );
  }
}
