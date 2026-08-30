import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/settings.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/controls.dart';
import '../../widgets/segmented_control.dart';
import '../../widgets/toast.dart';
import '../settings_card.dart';

/// 全局记忆。总开关三档，条目只能由记忆工具读写（功能协议 §7）。
class MemorySection extends StatelessWidget {
  const MemorySection({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final AppPalette palette = context.palette;
        final List<MemoryEntry> memories = settings.memories;

        return SettingsCard(
          title: '记忆',
          subtitle: '记忆存放在全局 memory.json，模型只能通过记忆工具访问，不会随对话自动带入。',
          children: <Widget>[
            SettingsRow(
              title: '记忆工具',
              desc: settings.memoryMode.desc,
              trailing: SegmentedControl<MemoryMode>(
                small: true,
                value: settings.memoryMode,
                options: MemoryMode.values
                    .map((MemoryMode m) => SegOption<MemoryMode>(m, m.label))
                    .toList(),
                onChanged: settings.setMemoryMode,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: <Widget>[
                SectionLabel('已保存 ${memories.length} 条'),
                const Spacer(),
                if (settings.memoryMode == MemoryMode.off)
                  Text(
                    '当前对模型不可见',
                    style: TextStyle(fontSize: 10.5, color: palette.warn),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            if (memories.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(
                  '还没有记忆条目。',
                  style: TextStyle(fontSize: 11.5, color: palette.text3),
                ),
              )
            else
              ...memories.map((MemoryEntry entry) => _MemoryRow(entry: entry)),
          ],
        );
      },
    );
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.entry});

  final MemoryEntry entry;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${entry.category} · ${entry.key}',
                  style: AppFonts.mono(size: 10.5, color: palette.accent),
                ),
                const SizedBox(height: 3),
                Text(
                  entry.value,
                  style: TextStyle(
                    fontSize: 12,
                    color: palette.text1,
                    height: 1.45,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  '更新于 ${entry.updatedAt}',
                  style: TextStyle(fontSize: 10, color: palette.text3),
                ),
              ],
            ),
          ),
          IconAction(
            icon: Icons.delete_outline,
            tooltip: '删除',
            size: 15,
            box: 28,
            tone: IconActionTone.danger,
            onTap: () => unawaited(_confirmDelete(context)),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除记忆', style: TextStyle(fontSize: 15)),
        content: Text(
          '将删除「${entry.category} · ${entry.key}」，删除后不可恢复。',
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
    if (confirmed != true || !context.mounted) return;
    context.settings.removeMemory(entry.id);
    showAppToast(context, '已删除该条记忆');
  }
}
