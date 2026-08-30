import 'package:flutter/material.dart';

import '../../../mock/mock_settings.dart';
import '../../../models/settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/controls.dart';
import '../../widgets/toast.dart';
import '../settings_card.dart';

/// 模型服务：供应商连接状态与可用模型。Key 只显示掩码。
class ProviderSection extends StatelessWidget {
  const ProviderSection({super.key});

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: '模型服务',
      subtitle: 'API Key 保存在本机，只在请求时使用；界面永不显示明文。',
      children: kProviders
          .map((ProviderInfo info) => _ProviderRow(info: info))
          .toList(),
    );
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.info});

  final ProviderInfo info;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: info.badgeColor.withValues(alpha: 0.16),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      color: info.badgeColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                info.name,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: palette.text1,
                ),
              ),
              const SizedBox(width: 8),
              info.connected
                  ? const Pill('已连接', tone: PillTone.good)
                  : const Pill('未配置'),
              const Spacer(),
              IconAction(
                icon: Icons.tune,
                tooltip: '配置',
                size: 15,
                box: 28,
                onTap: () => showAppToast(context, '编辑供应商（预览版未接入存储）'),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            info.maskedKey,
            style: AppFonts.mono(size: 11, color: palette.text3),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: info.models
                .map((String model) => _ModelChip(label: model))
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10.5, color: palette.text2),
      ),
    );
  }
}
