import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../theme/palette.dart';
import '../chat/chat_view.dart';
import '../sessions/session_list.dart';
import '../widgets/controls.dart';
import '../workspace/workspace_panel.dart';

/// 三栏布局：会话列表 · 聊天 · 工作区。左右两栏可拖宽、可收起。
class ExpandedShell extends StatefulWidget {
  const ExpandedShell({super.key});

  @override
  State<ExpandedShell> createState() => _ExpandedShellState();
}

class _ExpandedShellState extends State<ExpandedShell> {
  static const double _kRailWidth = 48;
  static const double _kLeftMin = 200;
  static const double _kLeftMax = 360;
  static const double _kRightMin = 220;
  static const double _kRightMax = 400;

  double _leftWidth = 260;
  double _rightWidth = 280;
  bool _leftOpen = true;
  bool _rightOpen = true;

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
    return Scaffold(
      backgroundColor: palette.bg,
      body: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_leftOpen)
            SizedBox(
              width: _leftWidth,
              child: SessionListPanel(
                onCollapse: () => setState(() => _leftOpen = false),
                collapseIcon: Icons.chevron_left,
              ),
            )
          else
            _Rail(
              width: _kRailWidth,
              color: palette.bgSide,
              children: <Widget>[
                IconAction(
                  icon: Icons.chevron_right,
                  tooltip: '展开会话列表',
                  onTap: () => setState(() => _leftOpen = true),
                ),
                IconAction(
                  icon: Icons.add,
                  tooltip: '新建会话',
                  onTap: () => context.sessions.createSession(
                    model: context.settings.defaultModel,
                  ),
                ),
              ],
            ),
          if (_leftOpen)
            _ResizeHandle(onDelta: _resizeLeft)
          else
            _Divider(color: palette.border),
          const Expanded(child: ChatView()),
          if (_rightOpen)
            _ResizeHandle(onDelta: _resizeRight)
          else
            _Divider(color: palette.border),
          if (_rightOpen)
            SizedBox(
              width: _rightWidth,
              child: WorkspacePanel(
                onCollapse: () => setState(() => _rightOpen = false),
                collapseIcon: Icons.chevron_right,
              ),
            )
          else
            _Rail(
              width: _kRailWidth,
              color: palette.bgPanel,
              children: <Widget>[
                IconAction(
                  icon: Icons.chevron_left,
                  tooltip: '展开工作区',
                  onTap: () => setState(() => _rightOpen = true),
                ),
              ],
            ),
        ],
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
            children: children
                .map(
                  (Widget child) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: child,
                  ),
                )
                .toList(),
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(width: 1, color: color);
  }
}

/// 分栏拖拽条：1px 的分割线 + 6px 的命中区域。
class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.onDelta});

  final ValueChanged<double> onDelta;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragUpdate: (DragUpdateDetails details) =>
            onDelta(details.delta.dx),
        child: SizedBox(
          width: 6,
          child: Center(
            child: SizedBox(
              width: 1,
              height: double.infinity,
              child: ColoredBox(color: palette.border),
            ),
          ),
        ),
      ),
    );
  }
}
