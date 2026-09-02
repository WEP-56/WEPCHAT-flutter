import 'package:flutter/foundation.dart';

/// 桌面外壳中由标题栏和内容区共同控制的展开状态。
class DesktopShellController extends ChangeNotifier {
  bool _leftOpen = true;
  bool _workspaceOpen = false;

  bool get leftOpen => _leftOpen;
  bool get workspaceOpen => _workspaceOpen;

  void toggleLeft() => _setLeftOpen(!_leftOpen);

  void toggleWorkspace() => _setWorkspaceOpen(!_workspaceOpen);

  void _setLeftOpen(bool value) {
    if (_leftOpen == value) return;
    _leftOpen = value;
    notifyListeners();
  }

  void _setWorkspaceOpen(bool value) {
    if (_workspaceOpen == value) return;
    _workspaceOpen = value;
    notifyListeners();
  }
}
