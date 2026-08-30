import 'dart:async';

import 'package:flutter/material.dart';

import '../../mock/mock_assets.dart';
import '../../models/chat.dart';
import '../../state/app_scope.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';

/// 聊天区顶栏：会话标题、模型选择、会话操作。
///
/// [onOpenSessions] / [onOpenWorkspace] 只在窄屏外壳里传入（打开抽屉），
/// 宽屏三栏布局下两侧面板常驻，传 null 即可隐藏对应按钮。
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.session,
    this.onOpenSessions,
    this.onOpenWorkspace,
  });

  final ChatSession session;
  final VoidCallback? onOpenSessions;
  final VoidCallback? onOpenWorkspace;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool hasDrawers = onOpenSessions != null || onOpenWorkspace != null;

    return Container(
      height: hasDrawers ? 48 : 44,
      padding: EdgeInsets.symmetric(horizontal: hasDrawers ? 6 : 12),
      decoration: BoxDecoration(
        color: palette.bg,
        border: Border(bottom: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: <Widget>[
          if (onOpenSessions != null)
            IconAction(
              icon: Icons.menu,
              tooltip: '会话列表',
              onTap: onOpenSessions!,
              box: 36,
            ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                session.title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13.5,
                  fontWeight: FontWeight.w600,
                  color: palette.text1,
                ),
              ),
            ),
          ),
          _ModelPicker(session: session),
          const SizedBox(width: 2),
          _SessionMenu(session: session),
          if (onOpenWorkspace != null)
            IconAction(
              icon: Icons.folder_outlined,
              tooltip: '工作区',
              onTap: onOpenWorkspace!,
              box: 36,
            ),
        ],
      ),
    );
  }
}

class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.session});

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return PopupMenuButton<String>(
      tooltip: '切换模型',
      position: PopupMenuPosition.under,
      onSelected: (String model) =>
          context.sessions.setModel(session.id, model),
      itemBuilder: (BuildContext _) {
        return kAvailableModels.map((String model) {
          return PopupMenuItem<String>(
            value: model,
            height: 38,
            child: Row(
              children: <Widget>[
                Icon(
                  model == session.model
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 14,
                  color: model == session.model
                      ? palette.accent
                      : palette.text3,
                ),
                const SizedBox(width: 8),
                Text(model, style: const TextStyle(fontSize: 12.5)),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: palette.bgRaise,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              session.model,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: palette.text1,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.expand_more, size: 15, color: palette.text3),
          ],
        ),
      ),
    );
  }
}

class _SessionMenu extends StatelessWidget {
  const _SessionMenu({required this.session});

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return PopupMenuButton<_SessionAction>(
      tooltip: '更多',
      position: PopupMenuPosition.under,
      onSelected: (_SessionAction action) {
        unawaited(_run(context, action));
      },
      itemBuilder: (BuildContext _) => <PopupMenuEntry<_SessionAction>>[
        const PopupMenuItem<_SessionAction>(
          value: _SessionAction.rename,
          height: 38,
          child: Text('重命名', style: TextStyle(fontSize: 12.5)),
        ),
        PopupMenuItem<_SessionAction>(
          value: _SessionAction.delete,
          height: 38,
          child: Text(
            '删除会话',
            style: TextStyle(fontSize: 12.5, color: palette.danger),
          ),
        ),
      ],
      child: SizedBox(
        width: 32,
        height: 32,
        child: Center(
          child: Icon(Icons.more_horiz, size: 17, color: palette.text2),
        ),
      ),
    );
  }

  Future<void> _run(BuildContext context, _SessionAction action) async {
    switch (action) {
      case _SessionAction.rename:
        await _rename(context);
      case _SessionAction.delete:
        await _confirmDelete(context);
    }
  }

  Future<void> _rename(BuildContext context) async {
    final TextEditingController controller = TextEditingController(
      text: session.title,
    );
    final String? title = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('重命名会话', style: TextStyle(fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(fontSize: 13.5),
          decoration: const InputDecoration(hintText: '会话标题'),
          onSubmitted: (String value) => Navigator.of(ctx).pop(value),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (title == null || !context.mounted) return;
    context.sessions.renameSession(session.id, title);
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('删除会话', style: TextStyle(fontSize: 15)),
        content: Text(
          '将删除「${session.title}」的对话记录。工作区文件不受影响。',
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
    context.sessions.deleteSession(
      session.id,
      fallbackModel: context.settings.defaultModel,
    );
  }
}

enum _SessionAction { rename, delete }
