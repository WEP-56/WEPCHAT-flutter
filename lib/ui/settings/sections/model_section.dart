import 'package:flutter/material.dart';

import '../../../ai/model_catalog.dart';
import '../../../ai/provider_config.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/menu_picker.dart';
import '../../widgets/segmented_control.dart';
import '../settings_card.dart';

/// 生成参数：默认模型、图片模型、温度。
///
/// 上下文长度不在这里：它是模型自身的元数据（[ModelSpec.contextWindow]），
/// 在模型详情里改；再放一个全局档位只会和模型上的值打架。
class ModelSection extends StatelessWidget {
  const ModelSection({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final AppPalette palette = context.palette;
        final List<SegOption<String>> models = _modelOptions(settings);
        return SettingsCard(
          title: '生成参数',
          subtitle: '新建会话时使用这里的默认值，单个会话可在顶栏临时切换模型。',
          children: <Widget>[
            SettingsRow(
              title: '默认模型',
              desc: models.isEmpty ? '还没有可用模型，先到「模型服务」添加提供商。' : null,
              trailing: _ModelPicker(
                tooltip: '选择默认模型',
                value: settings.defaultModelKey,
                options: models,
                onChanged: (String? key) {
                  if (key != null) settings.setDefaultModelKey(key);
                },
              ),
            ),
            SettingsRow(
              title: '图片生成模型',
              desc: '图片生成工具默认调用它。',
              trailing: _ModelPicker(
                tooltip: '选择图片生成模型',
                value: settings.imageGenModelKey,
                options: models,
                allowEmpty: true,
                onChanged: settings.setImageGenModel,
              ),
            ),
            SettingsRow(
              title: '图片编辑模型',
              desc: '图片编辑工具默认调用它。',
              trailing: _ModelPicker(
                tooltip: '选择图片编辑模型',
                value: settings.imageEditModelKey,
                options: models,
                allowEmpty: true,
                onChanged: settings.setImageEditModel,
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

  /// 展平所有提供商下的模型，标签带上提供商名以便区分同名模型。
  static List<SegOption<String>> _modelOptions(AppSettings settings) {
    return <SegOption<String>>[
      for (final (ProviderConfig p, List<ModelSpec> ms)
          in settings.modelsByProvider)
        for (final ModelSpec m in ms)
          SegOption<String>(m.key, '${p.displayName} · ${m.id}'),
    ];
  }
}

/// 模型下拉：无可选模型时降级为提示文案，避免 MenuPicker 找不到当前值。
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({
    required this.tooltip,
    required this.value,
    required this.options,
    required this.onChanged,
    this.allowEmpty = false,
  });

  final String tooltip;
  final String? value;
  final List<SegOption<String>> options;
  final ValueChanged<String?> onChanged;
  final bool allowEmpty;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    if (options.isEmpty) {
      return Text('暂无模型', style: TextStyle(fontSize: 12, color: palette.text3));
    }
    final List<SegOption<String>> all = <SegOption<String>>[
      if (allowEmpty) const SegOption<String>('', '跟随默认模型'),
      ...options,
    ];
    final String current = all.any((SegOption<String> o) => o.value == value)
        ? value!
        : all.first.value;
    return MenuPicker<String>(
      tooltip: tooltip,
      value: current,
      options: all,
      onChanged: (String v) => onChanged(v.isEmpty ? null : v),
    );
  }
}
