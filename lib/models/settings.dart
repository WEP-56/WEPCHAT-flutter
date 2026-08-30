import 'package:flutter/widgets.dart';

/// 单个工具的全局权限。作用于所有会话，不提供会话级特例（功能协议 §9）。
enum ToolPermission {
  denied('禁止'),
  ask('询问'),
  allowed('允许');

  const ToolPermission(this.label);

  final String label;
}

/// 记忆总开关三档（功能协议 §7.3）。
enum MemoryMode {
  off('关闭', '不向模型暴露记忆工具'),
  ask('询问', '每个新会话开始时询问'),
  allow('允许', '自动暴露记忆工具');

  const MemoryMode(this.label, this.desc);

  final String label;
  final String desc;
}

/// 工具权限行的静态定义（名称、说明、图标、默认档位）。
class ToolPermissionSpec {
  const ToolPermissionSpec({
    required this.id,
    required this.name,
    required this.desc,
    required this.icon,
    required this.defaultPermission,
  });

  final String id;
  final String name;
  final String desc;
  final IconData icon;
  final ToolPermission defaultPermission;
}

/// 模型供应商配置卡片的展示模型。
class ProviderInfo {
  const ProviderInfo({
    required this.id,
    required this.name,
    required this.badgeColor,
    required this.connected,
    required this.maskedKey,
    required this.models,
  });

  final String id;
  final String name;
  final Color badgeColor;
  final bool connected;

  /// 只展示掩码后的 Key，永不展示明文。
  final String maskedKey;

  final List<String> models;
}

/// 搜索后端（功能协议 §4.3：模型只看到 web_search，后端可切换）。
class SearchBackendSpec {
  const SearchBackendSpec({
    required this.id,
    required this.name,
    required this.desc,
  });

  final String id;
  final String name;
  final String desc;
}

/// memory.json 中的一条全局记忆。
class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.category,
    required this.key,
    required this.value,
    required this.updatedAt,
  });

  final String id;
  final String category;
  final String key;
  final String value;

  /// 展示用日期文本。
  final String updatedAt;
}
