import 'package:flutter/material.dart';

import '../../theme/palette.dart';
import '../chat/chat_view.dart';
import '../sessions/session_list.dart';
import '../workspace/workspace_panel.dart';

/// 窄屏外壳：聊天占满屏幕，会话列表与工作区放进左右抽屉。
class CompactShell extends StatefulWidget {
  const CompactShell({super.key});

  @override
  State<CompactShell> createState() => _CompactShellState();
}

class _CompactShellState extends State<CompactShell> {
  final GlobalKey<ScaffoldState> _scaffold = GlobalKey<ScaffoldState>();

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final double drawerWidth = (MediaQuery.sizeOf(context).width * 0.86).clamp(
      260.0,
      340.0,
    );

    return Scaffold(
      key: _scaffold,
      backgroundColor: palette.bg,
      // 抽屉不需要手势拖出：聊天区左右两侧都有可滑动内容，边缘拖拽容易误触。
      drawerEnableOpenDragGesture: false,
      endDrawerEnableOpenDragGesture: false,
      drawer: Drawer(
        width: drawerWidth,
        backgroundColor: palette.bgSide,
        child: SessionListPanel(
          onNavigate: () => _scaffold.currentState?.closeDrawer(),
          onCollapse: () => _scaffold.currentState?.closeDrawer(),
          collapseIcon: Icons.close,
        ),
      ),
      endDrawer: Drawer(
        width: drawerWidth,
        backgroundColor: palette.bgPanel,
        child: WorkspacePanel(
          onCollapse: () => _scaffold.currentState?.closeEndDrawer(),
          collapseIcon: Icons.close,
        ),
      ),
      body: SafeArea(
        child: ChatView(
          onOpenSessions: () => _scaffold.currentState?.openDrawer(),
          onOpenWorkspace: () => _scaffold.currentState?.openEndDrawer(),
        ),
      ),
    );
  }
}
