import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../state/app_scope.dart';
import '../../theme/palette.dart';
import '../chat/chat_view.dart';
import '../sessions/session_list.dart';
import '../widgets/controls.dart';
import '../workspace/workspace_panel.dart';
import 'desktop_shell_controller.dart';

/// 桌面布局：左侧导航层 + 右侧内容面（聊天与工作区）。
///
/// 聊天和工作区属于同一个内容面，右侧只保留一条低对比度的内部边界；
/// 左侧导航贯穿窗口高度，避免出现「四个独立面板」的视觉重量。
class ExpandedShell extends StatefulWidget {
  const ExpandedShell({super.key, required this.controller});

  final DesktopShellController controller;

  @override
  State<ExpandedShell> createState() => _ExpandedShellState();
}

class _ExpandedShellState extends State<ExpandedShell> {
  static const double _kRailWidth = 34;
  static const double _kLeftMin = 200;
  static const double _kLeftMax = 360;
  static const double _kRightMin = 220;
  static const double _kRightMax = 400;

  double _leftWidth = 260;
  double _rightWidth = 280;
  void _resizeLeft(double delta) {
    setState(() {
      _leftWidth = (_leftWidth + delta).clamp(_kLeftMin, _kLeftMax);
    });
  }

  void _resizeRight(double delta) {
    setState(() {
      _rightWidth = (_rightWidth - delta).clamp(_kRightMin, _kRightMax);
    });
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (BuildContext context, Widget? _) => Scaffold(
        backgroundColor: palette.bgSide,
        body: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ClipRect(
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                width: widget.controller.leftOpen ? _leftWidth : _kRailWidth,
                child: widget.controller.leftOpen
                    ? SessionListPanel(
                        onCollapse: widget.controller.toggleLeft,
                        collapseIcon: Icons.chevron_left,
                      )
                    : _Rail(
                        width: _kRailWidth,
                        color: palette.bgSide,
                        children: <Widget>[
                          IconAction(
                            icon: Icons.chevron_right,
                            tooltip: '展开会话列表',
                            onTap: widget.controller.toggleLeft,
                          ),
                          IconAction(
                            icon: Icons.add,
                            tooltip: '新建会话',
                            onTap: () => context.sessions.createSession(
                              model: context.settings.defaultModelKey,
                            ),
                          ),
                          const Spacer(),
                          IconAction(
                            icon: Icons.settings_outlined,
                            tooltip: '设置',
                            onTap: () => AppNav.openSettings(context),
                          ),
                          const SizedBox(height: 8),
                        ],
                      ),
              ),
            ),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 180),
              child: widget.controller.leftOpen
                  ? _ResizeHandle(
                      key: const ValueKey<String>('left-resize'),
                      onDelta: _resizeLeft,
                    )
                  : const _Divider(key: ValueKey<String>('left-divider')),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                  child: ColoredBox(
                    color: palette.bg,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: <Widget>[
                        Expanded(
                          child: ChatView(
                            workspaceOpen: widget.controller.workspaceOpen,
                            onToggleWorkspace:
                                widget.controller.toggleWorkspace,
                          ),
                        ),
                        // 右栏收起后整条都不留：开关已经放到聊天顶栏。
                        // 固定子内容配合裁剪宽度，面板会从右侧平滑滑入/退出。
                        ClipRect(
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeOutCubic,
                            width: widget.controller.workspaceOpen
                                ? _rightWidth + 6
                                : 0,
                            child: Align(
                              alignment: Alignment.centerRight,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  _ResizeHandle(onDelta: _resizeRight),
                                  SizedBox(
                                    width: _rightWidth,
                                    child: const WorkspacePanel(embedded: true),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 收起后的窄条。
class _Rail extends StatelessWidget {
  const _Rail({
    required this.width,
    required this.color,
    required this.children,
  });

  final double width;
  final Color color;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      color: color,
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Column(
            children: <Widget>[
              for (final Widget child in children)
                if (child is Spacer)
                  child
                else
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: child,
                  ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({super.key});

  @override
  Widget build(BuildContext context) {
    // 收起状态仍保留一点呼吸空间，但不画出垂直切割线。
    return const SizedBox(width: 4);
  }
}

/// 分栏拖拽条：保留命中区域，视觉上不画实体分割线。
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({super.key, required this.onDelta});

  final ValueChanged<double> onDelta;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            onDelta(details.delta.dx),
        child: SizedBox(width: 6, child: const SizedBox.expand()),
      ),
    );
  }
}
