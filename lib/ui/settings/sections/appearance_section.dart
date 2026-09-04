import 'package:flutter/material.dart';

import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/palette.dart';
import '../../../theme/fonts.dart';
import '../../widgets/segmented_control.dart';
import '../settings_card.dart';

/// 外观：主题、配色与字体大小。
class AppearanceSection extends StatelessWidget {
  const AppearanceSection({super.key});

  static const List<SegOption<ThemeMode>> _themeOptions =
      <SegOption<ThemeMode>>[
        SegOption<ThemeMode>(ThemeMode.system, '跟随系统'),
        SegOption<ThemeMode>(ThemeMode.light, '浅色'),
        SegOption<ThemeMode>(ThemeMode.dark, '深色'),
      ];

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        return SettingsCard(
          title: '外观',
          children: <Widget>[
            SettingsRow(
              title: '主题',
              trailing: SegmentedControl<ThemeMode>(
                small: true,
                value: settings.themeMode,
                options: _themeOptions,
                onChanged: settings.setThemeMode,
              ),
            ),
            SettingsRow(
              title: '配色',
              trailing: SizedBox(
                width: 330,
                child: Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 6,
                  runSpacing: 6,
                  children: AppAccent.values.map((AppAccent accent) {
                    return _AccentSwatch(
                      accent: accent,
                      selected: settings.accent == accent,
                      onTap: () => settings.setAccent(accent),
                    );
                  }).toList(),
                ),
              ),
            ),
            SettingsRow(
              title: '字体大小',
              desc: '调整整个界面的文字显示大小。',
              trailing: SegmentedControl<AppFontSize>(
                small: true,
                value: settings.fontSize,
                options: <SegOption<AppFontSize>>[
                  for (final AppFontSize size in AppFontSize.values)
                    SegOption<AppFontSize>(size, size.label),
                ],
                onChanged: settings.setFontSize,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _AccentSwatch extends StatelessWidget {
  const _AccentSwatch({
    required this.accent,
    required this.selected,
    required this.onTap,
  });

  final AppAccent accent;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Tooltip(
      message: accent.label,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? palette.bgRaise : Colors.transparent,
            border: Border.all(color: selected ? accent.color : palette.border),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Container(
            width: 14,
            height: 14,
            decoration: BoxDecoration(
              color: accent.color,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
