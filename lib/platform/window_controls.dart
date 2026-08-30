import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 可以从 Dart 侧发起拖拽调整的窗口边缘。
///
/// 只有顶边需要它：runner 把标题栏那一条并入了客户区，鼠标事件会直接进入
/// Flutter 视图，系统拿不到顶边的命中测试；左右和下方的边框仍在非客户区，
/// 由系统自己处理。
enum WindowEdge { top, topLeft, topRight }

/// 桌面窗口控制。
///
/// 这是全工程唯一判断「是否桌面窗口」的地方（AGENTS.md §7：平台差异集中在
/// 一处）。Windows runner 在 `win32_window.cpp` 里把系统标题栏并入客户区，
/// 标题栏改由 [WindowTitleBar] 绘制，按钮动作经 `wepchat/window` 通道回到
/// win32。其他平台 [isSupported] 为 false，界面不显示这一行，方法也不允许调用。
abstract final class WindowControls {
  static const MethodChannel _channel = MethodChannel('wepchat/window');

  static bool get isSupported =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  static Future<bool> isMaximized() => _invokeBool('isMaximized');

  /// 最大化 / 还原，返回切换之后的状态。
  static Future<bool> toggleMaximize() => _invokeBool('toggleMaximize');

  static Future<void> minimize() => _invoke('minimize');

  static Future<void> close() => _invoke('close');

  /// 交给系统的窗口拖动循环，这样贴靠（Snap）等行为与原生标题栏一致。
  static Future<void> startDrag() => _invoke('startDrag');

  static Future<void> startResize(WindowEdge edge) =>
      _invoke('startResize', edge.name);

  static Future<void> _invoke(String method, [Object? arguments]) async {
    _checkSupported(method);
    await _channel.invokeMethod<void>(method, arguments);
  }

  static Future<bool> _invokeBool(String method) async {
    _checkSupported(method);
    final bool? value = await _channel.invokeMethod<bool>(method);
    if (value == null) {
      throw StateError('窗口通道 $method 没有返回结果');
    }
    return value;
  }

  static void _checkSupported(String method) {
    if (isSupported) return;
    throw UnsupportedError('当前平台没有自定义窗口标题栏，不能调用 $method');
  }
}
