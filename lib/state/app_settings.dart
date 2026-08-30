import 'package:flutter/material.dart';

import '../mock/mock_assets.dart';
import '../mock/mock_settings.dart';
import '../models/settings.dart';
import '../theme/palette.dart';

/// 全局设置（纯前端阶段仅存在于内存中）。
///
/// 真实实现会由 `wep_storage` 做持久化；这里的取值在应用重启后会回到默认值，
/// 这是当前阶段的已知限制，不做假的持久化。
class AppSettings extends ChangeNotifier {
  AppSettings()
    : _permissions = <String, ToolPermission>{
        for (final ToolPermissionSpec spec in kToolPermissionSpecs)
          spec.id: spec.defaultPermission,
      };

  ThemeMode _themeMode = ThemeMode.dark;
  AppAccent _accent = AppAccent.x;
  final Map<String, ToolPermission> _permissions;
  MemoryMode _memoryMode = MemoryMode.allow;
  List<MemoryEntry> _memories = List<MemoryEntry>.of(kMemoryEntries);
  String _defaultModel = kAvailableModels.first;
  double _temperature = 0.7;
  String _contextWindow = kContextWindowOptions[1];
  String _searchBackendId = kSearchBackends.first.id;
  String _workspaceRoot = kDefaultWorkspaceRoot;

  ThemeMode get themeMode => _themeMode;
  AppAccent get accent => _accent;
  MemoryMode get memoryMode => _memoryMode;
  List<MemoryEntry> get memories => List<MemoryEntry>.unmodifiable(_memories);
  String get defaultModel => _defaultModel;
  double get temperature => _temperature;
  String get contextWindow => _contextWindow;
  String get searchBackendId => _searchBackendId;
  String get workspaceRoot => _workspaceRoot;

  ToolPermission permissionOf(String toolId) {
    final ToolPermission? value = _permissions[toolId];
    if (value == null) {
      throw ArgumentError.value(
        toolId,
        'toolId',
        '未在 kToolPermissionSpecs 中声明的工具',
      );
    }
    return value;
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    notifyListeners();
  }

  /// 顶部栏的一键切换：跟随系统时按当前解析结果取反。
  void toggleTheme(Brightness current) {
    setThemeMode(current == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
  }

  void setAccent(AppAccent accent) {
    if (_accent == accent) return;
    _accent = accent;
    notifyListeners();
  }

  void setPermission(String toolId, ToolPermission permission) {
    if (!_permissions.containsKey(toolId)) {
      throw ArgumentError.value(
        toolId,
        'toolId',
        '未在 kToolPermissionSpecs 中声明的工具',
      );
    }
    if (_permissions[toolId] == permission) return;
    _permissions[toolId] = permission;
    notifyListeners();
  }

  void setMemoryMode(MemoryMode mode) {
    if (_memoryMode == mode) return;
    _memoryMode = mode;
    notifyListeners();
  }

  /// 相同 `category + key` 视为更新，不重复制造条目（功能协议 §7.2）。
  void upsertMemory({
    required String category,
    required String key,
    required String value,
    required String updatedAt,
  }) {
    final MemoryEntry entry = MemoryEntry(
      id: '${category}_$key',
      category: category,
      key: key,
      value: value,
      updatedAt: updatedAt,
    );
    final int index = _memories.indexWhere((MemoryEntry e) => e.id == entry.id);
    if (index >= 0) {
      _memories[index] = entry;
    } else {
      _memories = <MemoryEntry>[entry, ..._memories];
    }
    notifyListeners();
  }

  void removeMemory(String id) {
    final int before = _memories.length;
    _memories = _memories.where((MemoryEntry e) => e.id != id).toList();
    if (_memories.length != before) notifyListeners();
  }

  void setDefaultModel(String model) {
    if (_defaultModel == model) return;
    _defaultModel = model;
    notifyListeners();
  }

  void setTemperature(double value) {
    if (_temperature == value) return;
    _temperature = value;
    notifyListeners();
  }

  void setContextWindow(String value) {
    if (_contextWindow == value) return;
    _contextWindow = value;
    notifyListeners();
  }

  void setSearchBackend(String id) {
    if (_searchBackendId == id) return;
    _searchBackendId = id;
    notifyListeners();
  }

  void setWorkspaceRoot(String path) {
    final String trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == _workspaceRoot) return;
    _workspaceRoot = trimmed;
    notifyListeners();
  }
}
