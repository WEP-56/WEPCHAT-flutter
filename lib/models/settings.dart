// ignore_for_file: curly_braces_in_flow_control_structures
import 'package:flutter/material.dart';
import '../core/ulid.dart';

/// 工作区根目录默认值。真实路径在首次用到时由 `wep_storage` 解析成绝对路径。
const String kDefaultWorkspaceRoot = r'~/WePChat/workspaces';

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

/// 权限档位的权威定义，默认值对齐功能协议 §9 的建议表。
///
/// 一个档位管一组工具（`Tool.permissionId` 指向这里的 id）：用户想的是
/// "能不能改我的文件"，不是"write_file 能不能、edit_file 能不能"。
///
/// `AppSettings` 读它作首启默认值，`PermissionGate` 读它取显示名，设置页
/// 读它渲染行。三处共用一份，加一个工具只改这里。
const List<ToolPermissionSpec> kToolPermissionSpecs = <ToolPermissionSpec>[
  ToolPermissionSpec(
    id: 'read_file',
    name: '读取工作区',
    desc: 'list_files · search_files · read_file',
    icon: Icons.folder_open_outlined,
    defaultPermission: ToolPermission.allowed,
  ),
  ToolPermissionSpec(
    id: 'write_file',
    name: '写入文件',
    desc: 'write_file · edit_file',
    icon: Icons.edit_note_outlined,
    defaultPermission: ToolPermission.ask,
  ),
  ToolPermissionSpec(
    id: 'delete_file',
    name: '删除文件',
    desc: 'delete_file，删除后不可恢复',
    icon: Icons.delete_outline,
    defaultPermission: ToolPermission.ask,
  ),
  ToolPermissionSpec(
    id: 'web_search',
    name: '联网搜索',
    desc: 'web_search，返回候选来源列表',
    icon: Icons.public,
    defaultPermission: ToolPermission.allowed,
  ),
  ToolPermissionSpec(
    id: 'web_fetch',
    name: '网页读取',
    desc: 'web_fetch，只读单个来源正文',
    icon: Icons.article_outlined,
    defaultPermission: ToolPermission.allowed,
  ),
  ToolPermissionSpec(
    id: 'run_js',
    name: '运行 JavaScript',
    desc: 'run_js，受限沙盒，无网络与进程权限',
    icon: Icons.terminal,
    defaultPermission: ToolPermission.ask,
  ),
  ToolPermissionSpec(
    id: 'gen_image',
    name: '图片生成',
    desc: 'gen_image，结果写入当前工作区',
    icon: Icons.image_outlined,
    defaultPermission: ToolPermission.allowed,
  ),
  ToolPermissionSpec(
    id: 'edit_image',
    name: '图片编辑',
    desc: 'edit_image，默认生成新文件',
    icon: Icons.auto_fix_high_outlined,
    defaultPermission: ToolPermission.allowed,
  ),
  ToolPermissionSpec(
    id: 'memory',
    name: '全局记忆',
    desc: 'save_memory · list_memory · read_memory · delete_memory',
    icon: Icons.psychology_outlined,
    defaultPermission: ToolPermission.allowed,
  ),
];

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

/// 搜索服务配置。和聊天 Provider 分开：用户可以用任意聊天模型，搜索则走另一把 Key。
class SearchProviderConfig {
  const SearchProviderConfig({
    required this.id,
    required this.name,
    required this.kind,
    required this.baseUrl,
    this.apiKey = '',
    this.builtin = false,
  });

  factory SearchProviderConfig.create({
    required String name,
    required String kind,
    required String baseUrl,
    String apiKey = '',
  }) => SearchProviderConfig(
    id: Ulid.generate(),
    name: name,
    kind: kind,
    baseUrl: baseUrl,
    apiKey: apiKey,
  );

  final String id;
  final String name;

  /// tavily / exa / serper / searxng / custom。
  final String kind;
  final String baseUrl;
  final String apiKey;
  final bool builtin;

  bool get configured => apiKey.trim().isNotEmpty || kind == 'searxng';
  String get maskedKey {
    if (apiKey.isEmpty) return '未配置';
    if (apiKey.length <= 10) return '••••••••';
    return '${apiKey.substring(0, 6)}••••${apiKey.substring(apiKey.length - 4)}';
  }

  SearchProviderConfig copyWith({
    String? name,
    String? kind,
    String? baseUrl,
    String? apiKey,
  }) => SearchProviderConfig(
    id: id,
    name: name ?? this.name,
    kind: kind ?? this.kind,
    baseUrl: baseUrl ?? this.baseUrl,
    apiKey: apiKey ?? this.apiKey,
    builtin: builtin,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'kind': kind,
    'baseUrl': baseUrl,
    'apiKey': apiKey,
    'builtin': builtin,
  };

  static SearchProviderConfig? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final String? id = raw['id'] as String?;
    final String? kind = raw['kind'] as String?;
    final String? base = raw['baseUrl'] as String?;
    if (id == null ||
        id.isEmpty ||
        kind == null ||
        base == null ||
        base.isEmpty)
      return null;
    return SearchProviderConfig(
      id: id,
      name: raw['name'] as String? ?? kind,
      kind: kind,
      baseUrl: base,
      apiKey: raw['apiKey'] as String? ?? '',
      builtin: raw['builtin'] as bool? ?? false,
    );
  }
}

const List<SearchProviderConfig> kSearchProviderPresets =
    <SearchProviderConfig>[
      SearchProviderConfig(
        id: 'tavily',
        name: 'Tavily',
        kind: 'tavily',
        baseUrl: 'https://api.tavily.com',
        builtin: true,
      ),
      SearchProviderConfig(
        id: 'exa',
        name: 'Exa',
        kind: 'exa',
        baseUrl: 'https://api.exa.ai',
        builtin: true,
      ),
      SearchProviderConfig(
        id: 'serper',
        name: 'Serper',
        kind: 'serper',
        baseUrl: 'https://google.serper.dev',
        builtin: true,
      ),
      SearchProviderConfig(
        id: 'searxng',
        name: 'SearXNG（自建）',
        kind: 'searxng',
        baseUrl: '',
        builtin: true,
      ),
    ];

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
