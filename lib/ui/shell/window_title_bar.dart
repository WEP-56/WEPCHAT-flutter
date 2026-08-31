import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../platform/window_controls.dart';
import '../../theme/palette.dart';

/// 自定义标题栏高度（逻辑像素）。
const double kWindowTitleBarHeight = 34;

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
  const WindowFrame({super.key, required this.palette, required this.child});

  /// 由 `WepChatApp` 解析后传入：builder 位于 Theme 之外，不能用 context.palette。
  final AppPalette palette;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!WindowControls.isSupported) return child;
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          WindowTitleBar(palette: palette),
          Expanded(child: ClipRect(child: child)),
        ],
      ),
    );
  }
}

/// 最小化 / 最大化 / 关闭那一行，外加拖动与顶边调整大小。
class WindowTitleBar extends StatefulWidget {
  const WindowTitleBar({super.key, required this.palette});

  final AppPalette palette;

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
      borderRgb: palette.borderStrong.toARGB32(),
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
    // 与聊天区同色、且不画分隔线：标题栏要看着像窗口的一部分，而不是贴上去的
    // 一条。窗口自身的边框颜色由 [_syncFrame] 交给 DWM。
    return ColoredBox(
      color: palette.bg,
      child: Row(
        children: <Widget>[
          Expanded(child: _buildDragArea()),
          _CaptionButton(
            icon: Icons.remove,
            iconSize: 15,
            palette: palette,
            onPressed: () => unawaited(WindowControls.minimize()),
          ),
          _CaptionButton(
            icon: _maximized ? Icons.filter_none : Icons.crop_square,
            iconSize: _maximized ? 11 : 14,
            palette: palette,
            onPressed: () => unawaited(_toggleMaximize()),
          ),
          _CaptionButton(
            icon: Icons.close,
            iconSize: 16,
            palette: palette,
            danger: true,
            onPressed: () => unawaited(WindowControls.close()),
          ),
        ],
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

/// 单个窗口按钮。尺寸与配色贴近 Windows 原生标题栏：46×34，关闭键悬停变红。
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
          width: 46,
          height: kWindowTitleBarHeight,
          color: background,
          alignment: Alignment.center,
          child: Icon(widget.icon, size: widget.iconSize, color: foreground),
        ),
      ),
    );
  }
}
