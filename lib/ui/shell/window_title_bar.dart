import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../platform/window_controls.dart';
import '../../theme/palette.dart';
import 'desktop_shell_controller.dart';

/// 自定义标题栏高度（逻辑像素）。
///
/// 比 Windows 原生标题栏（32）再窄一点：这条栏只放图标按钮，不显示标题文字，
/// 空间留给下方内容。顶边还要留 [_kResizeStripHeight] 给调整大小，不宜再压。
const double kWindowTitleBarHeight = 28;

/// 顶边可拖拽调整的厚度。
const double _kResizeStripHeight = 4;

/// 左右上角的斜向调整区域宽度。
const double _kResizeCornerWidth = 10;

/// 在 Windows 上给整个应用套一条自定义标题栏；其他平台原样返回 [child]。
///
/// 放在 `MaterialApp.builder` 里，所以它位于 Navigator 之上，全屏路由（设置、
/// 文件预览等）也在这条标题栏之下。这里不能使用 Tooltip / InkWell —— 它们需要
/// Overlay 与 Material 祖先，而两者都在 Navigator 内部。
class WindowFrame extends StatelessWidget {
  const WindowFrame({
    super.key,
    required this.palette,
    required this.shellController,
    required this.onNewSession,
    required this.onOpenSettings,
    required this.child,
  });

  /// 由 `WepChatApp` 解析后传入：builder 位于 Theme 之外，不能用 context.palette。
  final AppPalette palette;
  final DesktopShellController shellController;
  final VoidCallback onNewSession;
  final VoidCallback onOpenSettings;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!WindowControls.isSupported) return child;
    return Directionality(
      textDirection: TextDirection.ltr,
      // 整个窗口先垫一层不透明底色，再往上叠标题栏和内容。
      //
      // Flutter 的根画布每帧都清成透明黑，而 Windows 的窗口本身不做逐像素透明，
      // 所以任何没被 widget 完全覆盖的像素最终显示为黑色。标题栏高度换算成物理
      // 像素后若落在半个像素上（125% / 175% 缩放），交界那一行只被覆盖一半
      // （drawRect 默认抗锯齿），剩下一半透出根画布的黑，就会看到一条细黑线。
      // 垫上与标题栏同色的底之后，这一行混出来仍是同一片颜色，接缝不会出现。
      child: ColoredBox(
        color: palette.bgSide,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            WindowTitleBar(
              palette: palette,
              shellController: shellController,
              onNewSession: onNewSession,
              onOpenSettings: onOpenSettings,
            ),
            Expanded(child: ClipRect(child: child)),
          ],
        ),
      ),
    );
  }
}

/// 最小化 / 最大化 / 关闭那一行，外加拖动与顶边调整大小。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({
    super.key,
    required this.palette,
    required this.shellController,
    required this.onNewSession,
    required this.onOpenSettings,
  });

  final AppPalette palette;
  final DesktopShellController shellController;
  final VoidCallback onNewSession;
  final VoidCallback onOpenSettings;

  @override
  State<WindowTitleBar> createState() => _WindowTitleBarState();
}

class _WindowTitleBarState extends State<WindowTitleBar>
    with WidgetsBindingObserver {
  bool _maximized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_syncMaximized());
    unawaited(_syncFrame());
  }

  @override
  void didUpdateWidget(WindowTitleBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    final AppPalette old = oldWidget.palette;
    final AppPalette now = widget.palette;
    if (old.brightness != now.brightness ||
        old.borderStrong != now.borderStrong) {
      unawaited(_syncFrame());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// 把窗口边框交给应用主题：runner 默认跟随系统注册表的深浅色，系统深色而应用
  /// 浅色时四周会留一圈近黑的线，看着像标题栏与窗体裂开。
  Future<void> _syncFrame() {
    final AppPalette palette = widget.palette;
    return WindowControls.setFrameAppearance(
      dark: palette.brightness == Brightness.dark,
      // DWM 的外框与自绘标题栏同色，避免浅色模式留下深色边线。
      borderRgb: palette.bgSide.toARGB32(),
    );
  }

  /// 最大化状态也可能由系统改变（Win+↑、贴靠、任务栏菜单），这些都会带来一次
  /// 尺寸变化，所以在这里同步一次，而不是自己猜。
  @override
  void didChangeMetrics() {
    unawaited(_syncMaximized());
  }

  Future<void> _syncMaximized() async {
    final bool value = await WindowControls.isMaximized();
    if (!mounted || value == _maximized) return;
    setState(() => _maximized = value);
  }

  Future<void> _toggleMaximize() async {
    final bool value = await WindowControls.toggleMaximize();
    if (!mounted || value == _maximized) return;
    setState(() => _maximized = value);
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = widget.palette;
    return SizedBox(
      height: kWindowTitleBarHeight,
      child: Stack(
        children: <Widget>[
          Positioned.fill(child: _buildBar(palette)),
          // 最大化时不需要（也不该）调整大小。
          if (!_maximized)
            Positioned(top: 0, left: 0, right: 0, child: _buildResizeStrip()),
        ],
      ),
    );
  }

  Widget _buildBar(AppPalette palette) {
    // 与左侧导航同色：标题栏和导航组成一个连续的外壳，右侧内容面在下方
    // 用轻微的圆角和明度差自然浮起。窗口自身的边框颜色由 [_syncFrame] 交给 DWM。
    return ColoredBox(
      color: palette.bgSide,
      child: ListenableBuilder(
        listenable: widget.shellController,
        builder: (BuildContext context, Widget? _) => Row(
          children: <Widget>[
            _ToolbarButton(
              icon: widget.shellController.leftOpen
                  ? Icons.menu_open
                  : Icons.menu,
              label: '切换会话列表',
              palette: palette,
              onPressed: widget.shellController.toggleLeft,
            ),
            _ToolbarButton(
              icon: Icons.add_comment_outlined,
              label: '新建会话',
              palette: palette,
              onPressed: widget.onNewSession,
            ),
            Expanded(child: _buildDragArea()),
            _ToolbarButton(
              icon: widget.shellController.workspaceOpen
                  ? Icons.folder_open_outlined
                  : Icons.folder_outlined,
              label: '切换工作区',
              palette: palette,
              onPressed: widget.shellController.toggleWorkspace,
            ),
            _ToolbarButton(
              icon: Icons.settings_outlined,
              label: '打开设置',
              palette: palette,
              onPressed: widget.onOpenSettings,
            ),
            _CaptionButton(
              icon: Icons.remove,
              iconSize: 14,
              palette: palette,
              onPressed: () => unawaited(WindowControls.minimize()),
            ),
            _CaptionButton(
              icon: _maximized ? Icons.filter_none : Icons.crop_square,
              iconSize: _maximized ? 10 : 13,
              palette: palette,
              onPressed: () => unawaited(_toggleMaximize()),
            ),
            _CaptionButton(
              icon: Icons.close,
              iconSize: 15,
              palette: palette,
              danger: true,
              onPressed: () => unawaited(WindowControls.close()),
            ),
          ],
        ),
      ),
    );
  }

  /// 拖动用 onPanStart 而不是 onPointerDown：这样双击最大化仍然能识别，
  /// 鼠标的 pan 判定阈值只有 1 逻辑像素，手感上仍是「按下即拖」。
  Widget _buildDragArea() {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onDoubleTap: () => unawaited(_toggleMaximize()),
      onPanStart: (DragStartDetails _) => unawaited(WindowControls.startDrag()),
      child: const SizedBox.expand(),
    );
  }

  Widget _buildResizeStrip() {
    return const SizedBox(
      height: _kResizeStripHeight,
      child: Row(
        children: <Widget>[
          SizedBox(
            width: _kResizeCornerWidth,
            child: _ResizeHandle(
              edge: WindowEdge.topLeft,
              cursor: SystemMouseCursors.resizeUpLeft,
            ),
          ),
          Expanded(
            child: _ResizeHandle(
              edge: WindowEdge.top,
              cursor: SystemMouseCursors.resizeUp,
            ),
          ),
          SizedBox(
            width: _kResizeCornerWidth,
            child: _ResizeHandle(
              edge: WindowEdge.topRight,
              cursor: SystemMouseCursors.resizeUpRight,
            ),
          ),
        ],
      ),
    );
  }
}

class _ToolbarButton extends StatefulWidget {
  const _ToolbarButton({
    required this.icon,
    required this.label,
    required this.palette,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final AppPalette palette;
  final VoidCallback onPressed;

  @override
  State<_ToolbarButton> createState() => _ToolbarButtonState();
}

class _ToolbarButtonState extends State<_ToolbarButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    // WindowFrame 位于 Navigator / Overlay 之上，不能使用 Tooltip；
    // 标题栏按钮也不加入 Flutter 语义树，避免悬停重建时向 Windows
    // accessibility bridge 发送短暂失效的节点 ID。
    return MouseRegion(
      onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
      onExit: (PointerExitEvent _) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          width: 34,
          height: kWindowTitleBarHeight,
          color: _hovered ? widget.palette.hover : Colors.transparent,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: 15, color: widget.palette.text2),
        ),
      ),
    );
  }
}

class _ResizeHandle extends StatelessWidget {
  const _ResizeHandle({required this.edge, required this.cursor});

  final WindowEdge edge;
  final MouseCursor cursor;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: cursor,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (PointerDownEvent event) {
          if (event.buttons != kPrimaryMouseButton) return;
          unawaited(WindowControls.startResize(edge));
        },
      ),
    );
  }
}

/// 单个窗口按钮。配色贴近 Windows 原生标题栏：40×28，关闭键悬停变红。
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.icon,
    required this.iconSize,
    required this.palette,
    required this.onPressed,
    this.danger = false,
  });

  final IconData icon;
  final double iconSize;
  final AppPalette palette;
  final VoidCallback onPressed;
  final bool danger;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = widget.palette;
    final Color background = switch ((_hovered, widget.danger)) {
      (false, _) => Colors.transparent,
      (true, true) => palette.danger,
      (true, false) => palette.bgRaise,
    };
    final Color foreground = _hovered && widget.danger
        ? const Color(0xFFFFFFFF)
        : palette.text2;

    return MouseRegion(
      onEnter: (PointerEnterEvent _) => setState(() => _hovered = true),
      onExit: (PointerExitEvent _) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onPressed,
        child: Container(
          width: 40,
          height: kWindowTitleBarHeight,
          color: background,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: widget.iconSize, color: foreground),
        ),
      ),
    );
  }
}
