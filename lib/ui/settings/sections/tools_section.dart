import 'package:flutter/material.dart';

import '../../../mock/mock_settings.dart';
import '../../../models/settings.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/palette.dart';
import '../../widgets/segmented_control.dart';
import '../settings_card.dart';

/// 工具权限。档位是全局的，不提供会话级特例（功能协议 §9）。
class ToolsSection extends StatelessWidget {
  const ToolsSection({super.key});

  static const List<SegOption<ToolPermission>> _options =
      <SegOption<ToolPermission>>[
        SegOption<ToolPermission>(ToolPermission.denied, '禁止'),
        SegOption<ToolPermission>(ToolPermission.ask, '询问'),
        SegOption<ToolPermission>(ToolPermission.allowed, '允许'),
      ];

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        return SettingsCard(
          title: '工具权限',
          subtitle: '「询问」会在每次调用前弹出确认，并显示将要执行的参数。',
          children: kToolPermissionSpecs.map((ToolPermissionSpec spec) {
            return _ToolRow(
              spec: spec,
              value: settings.permissionOf(spec.id),
              options: _options,
              onChanged: (ToolPermission p) =>
                  settings.setPermission(spec.id, p),
            );
          }).toList(),
        );
      },
    );
  }
}

class _ToolRow extends StatelessWidget {
  const _ToolRow({
    required this.spec,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final ToolPermissionSpec spec;
  final ToolPermission value;
  final List<SegOption<ToolPermission>> options;
  final ValueChanged<ToolPermission> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return SettingsRow(
      title: spec.name,
      desc: spec.desc,
      leading: Icon(spec.icon, size: 16, color: palette.text2),
      trailing: SegmentedControl<ToolPermission>(
        small: true,
        value: value,
        options: options,
        onChanged: onChanged,
      ),
    );
  }
}
