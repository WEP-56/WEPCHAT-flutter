import 'package:flutter/material.dart';

import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/palette.dart';
import '../../widgets/segmented_control.dart';
import '../settings_card.dart';

/// 外观：主题与强调色。
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
              title: '强调色',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: AppAccent.values.map((AppAccent accent) {
                  return Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: _AccentSwatch(
                      accent: accent,
                      selected: settings.accent == accent,
                      onTap: () => settings.setAccent(accent),
                    ),
                  );
                }).toList(),
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
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: accent.color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Text(
                accent.label,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                  color: palette.text1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
