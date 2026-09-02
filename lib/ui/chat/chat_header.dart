import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/model_catalog.dart';
import '../../ai/provider_config.dart';
import '../../models/chat.dart';
import '../../state/app_scope.dart';
import '../../state/app_settings.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';

/// 聊天区顶栏：会话标题、模型选择、会话操作、工作区开关。
///
/// [onOpenSessions] 只在窄屏外壳里传入（打开抽屉），宽屏左栏常驻，传 null 即可
/// 隐藏该按钮。[onToggleWorkspace] 两种外壳都会传：窄屏打开右抽屉，宽屏收起 /
/// 展开右栏，[workspaceOpen] 决定按钮显示的是「展开」还是「收起」。
class ChatHeader extends StatelessWidget {
  const ChatHeader({
    super.key,
    required this.session,
    this.onOpenSessions,
    this.onToggleWorkspace,
    this.workspaceOpen = false,
  });

  final ChatSession session;
  final VoidCallback? onOpenSessions;
  final VoidCallback? onToggleWorkspace;
  final bool workspaceOpen;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool hasMenu = onOpenSessions != null;

    return Container(
      height: hasMenu ? 48 : 44,
      padding: EdgeInsets.only(left: hasMenu ? 6 : 12, right: 6),
      color: palette.bg,
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
          if (onToggleWorkspace != null)
            IconAction(
              icon: workspaceOpen ? Icons.chevron_right : Icons.folder_outlined,
              tooltip: workspaceOpen ? '收起工作区' : '展开工作区',
              onTap: onToggleWorkspace!,
              box: 36,
            ),
        ],
      ),
    );
  }
}

/// 顶栏的模型选择器，按提供商分组。
///
/// 选项来自设置里的模型清单（用户自己配的），分组头是 provider 名——同一个
/// 模型 id 挂在两个 provider 下是常见的（官方端点 + 中转站），不写 provider
/// 名就分不清点的是哪个。
class _ModelPicker extends StatelessWidget {
  const _ModelPicker({required this.session});

  final ChatSession session;

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final AppPalette palette = context.palette;
        final ModelSpec? current = settings.modelByKey(session.model);

        return PopupMenuButton<String>(
          tooltip: '切换模型',
          position: PopupMenuPosition.under,
          onSelected: (String key) =>
              context.sessions.setModel(session.id, key),
          itemBuilder: (BuildContext _) => _entries(settings, palette),
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
                  // 会话记的 key 在设置里找不到（模型被删了）时显示原文，
                  // 让用户看得出"这个会话指着一个没了的模型"。
                  current?.displayName ??
                      (session.model.isEmpty ? '选择模型' : session.model),
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w500,
                    color: current == null ? palette.warn : palette.text1,
                  ),
                ),
                const SizedBox(width: 3),
                Icon(Icons.expand_more, size: 15, color: palette.text3),
              ],
            ),
          ),
        );
      },
    );
  }

  List<PopupMenuEntry<String>> _entries(
    AppSettings settings,
    AppPalette palette,
  ) {
    final List<PopupMenuEntry<String>> entries = <PopupMenuEntry<String>>[];

    for (final (ProviderConfig p, List<ModelSpec> models)
        in settings.modelsByProvider) {
      // 空 provider 不进菜单：设置页要显示它（提示去加模型），
      // 但菜单里一个没有内容的组头只是噪音。
      if (models.isEmpty) continue;
      if (entries.isNotEmpty) entries.add(const PopupMenuDivider());
      entries.add(
        PopupMenuItem<String>(
          enabled: false,
          height: 26,
          child: Text(
            p.displayName,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.3,
              color: palette.text3,
            ),
          ),
        ),
      );
      for (final ModelSpec m in models) {
        final bool active = m.key == session.model;
        entries.add(
          PopupMenuItem<String>(
            value: m.key,
            height: 36,
            child: Row(
              children: <Widget>[
                Icon(
                  active
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 14,
                  color: active ? palette.accent : palette.text3,
                ),
                const SizedBox(width: 8),
                Text(m.displayName, style: const TextStyle(fontSize: 12.5)),
              ],
            ),
          ),
        );
      }
    }

    if (entries.isEmpty) {
      entries.add(
        PopupMenuItem<String>(
          enabled: false,
          height: 36,
          child: Text(
            '还没有模型，去设置页添加',
            style: TextStyle(fontSize: 12, color: palette.text3),
          ),
        ),
      );
    }
    return entries;
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
    await context.sessions.renameSession(session.id, title);
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
    await context.sessions.deleteSession(
      session.id,
      fallbackModel: context.settings.defaultModelKey,
    );
  }
}

enum _SessionAction { rename, delete }
