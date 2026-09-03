import 'dart:async';

import 'package:flutter/material.dart';

import '../../theme/palette.dart';

/// 同时服务触屏长按与桌面右键的菜单项。
class ContextAction {
  const ContextAction({
    required this.label,
    required this.icon,
    required this.onSelected,
    this.destructive = false,
  });

  final String label;
  final IconData icon;
  final FutureOr<void> Function() onSelected;
  final bool destructive;
}

/// 为列表项补上跨平台上下文菜单，不接管其原有的主点击行为。
class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.actions,
    required this.child,
  });

  final List<ContextAction> actions;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPressStart: (LongPressStartDetails details) =>
          unawaited(_show(context, details.globalPosition)),
      onSecondaryTapDown: (TapDownDetails details) =>
          unawaited(_show(context, details.globalPosition)),
      child: child,
    );
  }

  Future<void> _show(BuildContext context, Offset globalPosition) async {
    final OverlayState overlay = Overlay.of(context);
    final RenderBox box = overlay.context.findRenderObject()! as RenderBox;
    final Offset position = box.globalToLocal(globalPosition);
    final ContextAction? selected = await showMenu<ContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        position.dx,
        position.dy,
        box.size.width - position.dx,
        box.size.height - position.dy,
      ),
      items: actions.map((ContextAction action) {
        final AppPalette palette = context.palette;
        final Color color = action.destructive ? palette.danger : palette.text1;
        return PopupMenuItem<ContextAction>(
          value: action,
          child: Row(
            children: <Widget>[
              Icon(action.icon, size: 17, color: color),
              const SizedBox(width: 10),
              Text(action.label, style: TextStyle(color: color)),
            ],
          ),
        );
      }).toList(),
    );
    if (selected != null) await selected.onSelected();
  }
}
