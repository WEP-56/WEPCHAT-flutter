import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/settings.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../storage/storage.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/controls.dart';
import '../../widgets/segmented_control.dart';
import '../../widgets/toast.dart';
import '../settings_card.dart';

/// 全局记忆。总开关三档，条目由记忆工具读写（功能协议 §7）。
class MemorySection extends StatefulWidget {
  const MemorySection({super.key});

  @override
  State<MemorySection> createState() => _MemorySectionState();
}

class _MemorySectionState extends State<MemorySection> {
  List<MemorySummary>? _memories;
  String? _error;

  @override
  void initState() {
    super.initState();
    // 延迟到 build 之后再加载，避免在 initState 中访问 InheritedWidget
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _loadMemories();
    });
  }

  Future<void> _loadMemories() async {
    if (!mounted) return;

    try {
      final WepStorage storage = context.sessions.storage;
      final List<MemorySummary> memories = await storage.listMemories();
      if (mounted) {
        setState(() {
          _memories = memories;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = '加载失败：$e';
        });
      }
    }
  }

  Future<void> _deleteMemory(String id) async {
    try {
      final WepStorage storage = context.sessions.storage;
      await storage.deleteMemory(id);
      await _loadMemories();
      if (mounted) {
        showAppToast(context, '已删除该条记忆');
      }
    } on Object catch (e) {
      if (mounted) {
        showAppToast(context, '删除失败：$e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final AppPalette palette = context.palette;
        final List<MemorySummary>? memories = _memories;

        return SettingsCard(
          title: '记忆',
          subtitle:
              '记忆存放在数据库，模型通过记忆工具访问。分三层：'
              'user_profile（用户画像）、user_preference（用户倾向）、volatile（波动区域）。',
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
            if (_error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  _error!,
                  style: TextStyle(fontSize: 11.5, color: palette.danger),
                ),
              )
            else if (memories == null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 10),
                child: Center(child: CircularProgressIndicator()),
              )
            else ...<Widget>[
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
                    '还没有记忆条目。模型会在对话中自动创建。',
                    style: TextStyle(fontSize: 11.5, color: palette.text3),
                  ),
                )
              else
                ..._buildMemoryGroups(memories, palette),
            ],
          ],
        );
      },
    );
  }

  List<Widget> _buildMemoryGroups(
    List<MemorySummary> memories,
    AppPalette palette,
  ) {
    final Map<String, List<MemorySummary>> grouped =
        <String, List<MemorySummary>>{};
    for (final MemorySummary m in memories) {
      grouped.putIfAbsent(m.category, () => <MemorySummary>[]).add(m);
    }

    final List<Widget> widgets = <Widget>[];
    const Map<String, String> categoryLabels = <String, String>{
      'user_profile': '用户画像',
      'user_preference': '用户倾向',
      'volatile': '波动区域',
    };

    for (final String category in <String>[
      'user_profile',
      'user_preference',
      'volatile',
    ]) {
      final List<MemorySummary>? items = grouped[category];
      if (items == null || items.isEmpty) continue;

      widgets.add(
        Padding(
          padding: const EdgeInsets.only(top: 12, bottom: 4),
          child: Text(
            '${categoryLabels[category] ?? category} (${items.length})',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: palette.text2,
            ),
          ),
        ),
      );

      for (final MemorySummary memory in items) {
        widgets.add(
          _MemoryRow(memory: memory, onDelete: () => _deleteMemory(memory.id)),
        );
      }
    }

    return widgets;
  }
}

class _MemoryRow extends StatelessWidget {
  const _MemoryRow({required this.memory, required this.onDelete});

  final MemorySummary memory;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: palette.border, width: 0.5),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  memory.key,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: palette.text1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  memory.summary,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: palette.text2,
                    height: 1.45,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  '更新于 ${_formatDate(memory.updatedAt)}',
                  style: AppFonts.mono(size: 10, color: palette.text3),
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

  String _formatDate(DateTime dt) {
    final DateTime now = DateTime.now();
    final Duration diff = now.difference(dt);

    if (diff.inDays == 0) {
      return '今天 ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    } else if (diff.inDays == 1) {
      return '昨天';
    } else if (diff.inDays < 7) {
      return '${diff.inDays} 天前';
    } else {
      return '${dt.month}/${dt.day}';
    }
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除记忆', style: TextStyle(fontSize: 15)),
        content: Text(
          '将删除「${memory.key}」，删除后不可恢复。',
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
    if (confirmed == true) {
      onDelete();
    }
  }
}
