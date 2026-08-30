import 'package:flutter/material.dart';

import '../../../mock/mock_assets.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/menu_picker.dart';
import '../../widgets/segmented_control.dart';
import '../settings_card.dart';

/// 生成参数：默认模型、上下文长度、温度。
class ModelSection extends StatelessWidget {
  const ModelSection({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final AppPalette palette = context.palette;
        return SettingsCard(
          title: '生成参数',
          subtitle: '新建会话时使用这里的默认值，单个会话可在顶栏临时切换模型。',
          children: <Widget>[
            SettingsRow(
              title: '默认模型',
              trailing: MenuPicker<String>(
                tooltip: '选择默认模型',
                value: settings.defaultModel,
                options: kAvailableModels
                    .map((String m) => SegOption<String>(m, m))
                    .toList(),
                onChanged: settings.setDefaultModel,
              ),
            ),
            SettingsRow(
              title: '上下文长度',
              desc: '超出后按时间顺序裁剪较早的消息。',
              trailing: SegmentedControl<String>(
                small: true,
                value: settings.contextWindow,
                options: kContextWindowOptions
                    .map((String o) => SegOption<String>(o, o))
                    .toList(),
                onChanged: settings.setContextWindow,
              ),
            ),
            SettingsRow(
              title: '温度',
              desc: '越低越稳定，越高越发散。',
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 44,
                    child: Text(
                      settings.temperature.toStringAsFixed(1),
                      style: AppFonts.mono(size: 11.5, color: palette.text2),
                    ),
                  ),
                  SizedBox(
                    width: 170,
                    child: Slider(
                      value: settings.temperature,
                      min: 0,
                      max: 2,
                      divisions: 20,
                      onChanged: settings.setTemperature,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
