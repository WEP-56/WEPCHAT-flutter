/// 模型服务：提供商列表 + 增删改（实施 TODO §10-4）。
///
/// 一个 provider 一行：名字、协议、Key 状态、模型数量。真正的编辑动作都在
/// 弹窗里（`provider_dialog.dart` / `models_dialog.dart`），这一层只做导航。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../ai/provider_config.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/controls.dart';
import '../models_dialog.dart';
import '../provider_dialog.dart';
import '../settings_card.dart';

class ProviderSection extends StatelessWidget {
  const ProviderSection({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        return SettingsCard(
          title: '模型服务',
          subtitle: 'API Key 保存在本机，只在请求时使用；界面永不显示明文。',
          children: <Widget>[
            for (final ProviderConfig p in settings.providers)
              _ProviderRow(
                config: p,
                modelCount: settings.modelsOfProvider(p.id).length,
              ),
            const SizedBox(height: 6),
            Align(
              alignment: Alignment.centerLeft,
              child: OutlinedButton.icon(
                onPressed: () => unawaited(_add(context)),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加提供商'),
              ),
            ),
          ],
        );
      },
    );
  }

  /// 新建之后直接把模型弹窗接上去：刚填完 key 的下一步一定是挑模型，
  /// 让用户自己再点一次「模型」是多余的一步。
  Future<void> _add(BuildContext context) async {
    final ProviderConfig? created = await showProviderDialog(context);
    if (created == null || !context.mounted) return;
    await showModelsDialog(context, created.id);
  }
}

class _ProviderRow extends StatelessWidget {
  const _ProviderRow({required this.config, required this.modelCount});

  final ProviderConfig config;
  final int modelCount;

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
              Flexible(
                child: Text(
                  config.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: palette.text1,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Pill(config.apiKind.label, tone: PillTone.accent),
              const SizedBox(width: 6),
              config.isConfigured
                  ? const Pill('已配置', tone: PillTone.good)
                  : const Pill('未配置 Key', tone: PillTone.warn),
              const Spacer(),
              IconAction(
                icon: Icons.tune,
                tooltip: '编辑',
                size: 15,
                box: 28,
                onTap: () => unawaited(showProviderDialog(
                  context,
                  existing: config,
                )),
              ),
              // 内置 provider 不给删（删了下次启动还会回来）。
              if (!config.builtin)
                IconAction(
                  icon: Icons.delete_outline,
                  tooltip: '删除',
                  size: 15,
                  box: 28,
                  tone: IconActionTone.danger,
                  onTap: () => unawaited(_confirmRemove(context)),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '${config.maskedKey} · ${config.baseUrl}',
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.mono(size: 10.5, color: palette.text3),
                ),
              ),
              const SizedBox(width: 8),
              TextButton.icon(
                onPressed: () => unawaited(showModelsDialog(
                  context,
                  config.id,
                )),
                icon: const Icon(Icons.list_alt, size: 15),
                label: Text(modelCount == 0 ? '添加模型' : '模型 $modelCount'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _confirmRemove(BuildContext context) async {
    final AppSettings settings = context.settings;
    final int count = settings.modelsOfProvider(config.id).length;
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除提供商', style: TextStyle(fontSize: 15)),
        content: Text(
          count == 0
              ? '删除「${config.displayName}」？'
              : '删除「${config.displayName}」，它下面的 $count 个模型也会一起删掉。',
          style: const TextStyle(fontSize: 13),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok ?? false) settings.removeProvider(config.id);
  }
}
