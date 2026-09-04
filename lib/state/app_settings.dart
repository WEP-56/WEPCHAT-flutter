// ignore_for_file: curly_braces_in_flow_control_structures
import 'dart:async';

import 'package:flutter/material.dart';

import '../ai/model_catalog.dart';
import '../ai/model_compat.dart';
import '../ai/provider_config.dart';
import '../mock/mock_settings.dart';
import '../models/settings.dart';
import '../platform/settings_store.dart';
import '../theme/fonts.dart';
import '../theme/palette.dart';

part 'app_settings_parsing.dart';

/// 全局设置，落在 App 私有目录的 settings.json 里（实施 TODO §13.4）。
///
/// 构造前先 [load]：设置要在首帧之前就绪，界面才不用处理"加载中"分支。
///
/// 每次变更后异步写盘，写失败不回滚内存状态——内存是权威，盘只是下次启动的
/// 来源。写失败会记在 [lastWriteError] 上，设置页据此提示用户。
class AppSettings extends ChangeNotifier {
  AppSettings._({
    required SettingsStore? store,
    required List<ProviderConfig> providers,
    required List<ModelSpec> models,
    required Map<String, ToolPermission> permissions,
    required String defaultModelKey,
    required String? imageGenModelKey,
    required String? imageEditModelKey,
    required ThemeMode themeMode,
    required AppAccent accent,
    required AppFontSize fontSize,
    required MemoryMode memoryMode,
    required String customSystemPrompt,
    required bool autoCheckUpdates,
    required double temperature,
    required String searchBackendId,
    required String searchApiKey,
    required String searchBaseUrl,
    required List<SearchProviderConfig> searchProviders,
    required String workspaceRoot,
  }) : _store = store,
       _providers = providers,
       _models = models,
       _permissions = permissions,
       _defaultModelKey = defaultModelKey,
       _imageGenModelKey = imageGenModelKey,
       _imageEditModelKey = imageEditModelKey,
       _themeMode = themeMode,
       _accent = accent,
       _fontSize = fontSize,
       _memoryMode = memoryMode,
       _customSystemPrompt = customSystemPrompt,
       _autoCheckUpdates = autoCheckUpdates,
       _temperature = temperature,
       _searchBackendId = searchBackendId,
       _searchApiKey = searchApiKey,
       _searchBaseUrl = searchBaseUrl,
       _searchProviders = searchProviders,
       _workspaceRoot = workspaceRoot;

  /// 从磁盘读。文件不存在时用默认值（首次启动）。
  ///
  /// [store] 传 null 得到一个纯内存实例，给 widget 测试用——不落盘就不会
  /// 在测试之间互相污染，也不会在 fake-async 区里挂住真实 IO。
  static AppSettings load(SettingsStore? store) {
    final Map<String, Object?> json = store == null
        ? const <String, Object?>{}
        : store.read();

    return AppSettings._(
      store: store,
      providers: _readProviders(json['providers']),
      models: _readModels(json['models']),
      permissions: _readPermissions(json['permissions']),
      defaultModelKey: json['defaultModelKey'] as String? ?? '',
      imageGenModelKey: json['imageGenModelKey'] as String?,
      imageEditModelKey: json['imageEditModelKey'] as String?,
      themeMode: _readEnum(
        json['themeMode'],
        ThemeMode.values,
        ThemeMode.dark,
        (ThemeMode v) => v.name,
      ),
      accent: _readEnum(
        json['accent'],
        AppAccent.values,
        AppAccent.x,
        (AppAccent v) => v.name,
      ),
      fontSize: _readEnum(
        json['fontSize'],
        AppFontSize.values,
        AppFontSize.medium,
        (AppFontSize v) => v.name,
      ),
      memoryMode: _readEnum(
        json['memoryMode'],
        MemoryMode.values,
        MemoryMode.allow,
        (MemoryMode v) => v.name,
      ),
      customSystemPrompt: json['customSystemPrompt'] as String? ?? '',
      autoCheckUpdates: json['autoCheckUpdates'] as bool? ?? true,
      temperature: (json['temperature'] as num?)?.toDouble().clamp(0, 2) ?? 0.7,
      searchBackendId:
          json['searchBackendId'] as String? ?? kSearchBackends.first.id,
      searchApiKey: json['searchApiKey'] as String? ?? '',
      searchBaseUrl:
          json['searchBaseUrl'] as String? ?? 'https://api.tavily.com',
      searchProviders: _readSearchProviders(
        json['searchProviders'],
        legacyId: json['searchBackendId'] as String?,
        legacyKey: json['searchApiKey'] as String?,
        legacyBaseUrl: json['searchBaseUrl'] as String?,
      ),
      workspaceRoot: json['workspaceRoot'] as String? ?? kDefaultWorkspaceRoot,
    );
  }

  /// 纯内存实例，不落盘。
  static AppSettings memory() => load(null);

  final SettingsStore? _store;

  /// 用列表而不是 Map：界面要按用户的排列顺序显示，Map 的插入序在删除
  /// 再添加之后就和用户看到的顺序脱节了。查找量级是个位数，线性够用。
  List<ProviderConfig> _providers;
  List<ModelSpec> _models;

  final Map<String, ToolPermission> _permissions;

  String _defaultModelKey;

  /// 图片工具的默认模型。null = 跟随默认模型。
  String? _imageGenModelKey;
  String? _imageEditModelKey;

  ThemeMode _themeMode;
  AppAccent _accent;
  AppFontSize _fontSize;
  MemoryMode _memoryMode;
  String _customSystemPrompt;
  bool _autoCheckUpdates;
  double _temperature;
  String _searchBackendId;
  String _searchApiKey;
  String _searchBaseUrl;
  List<SearchProviderConfig> _searchProviders;
  String _workspaceRoot;

  /// 记忆条目。
  ///
  /// **只在内存里**，不进 settings.json：记忆的归宿是 SQLite 表（偏离 A，
  /// M6 落地）。写进设置文件等于建一份将来要迁移的第二数据源。
  /// 现在设置页能看到的是 mock 数据，改动重启后回到默认——这是 M6 之前的
  /// 已知限制，不做假的持久化。
  List<MemoryEntry> _memories = List<MemoryEntry>.of(kMemoryEntries);

  Timer? _writeTimer;
  Object? _lastWriteError;

  /// 上次写盘的失败原因，null 表示一切正常。设置页可以据此提示。
  Object? get lastWriteError => _lastWriteError;

  ThemeMode get themeMode => _themeMode;
  AppAccent get accent => _accent;
  AppFontSize get fontSize => _fontSize;
  MemoryMode get memoryMode => _memoryMode;
  String get customSystemPrompt => _customSystemPrompt;
  bool get autoCheckUpdates => _autoCheckUpdates;
  double get temperature => _temperature;
  String get searchBackendId => _searchBackendId;
  List<SearchProviderConfig> get searchProviders =>
      List<SearchProviderConfig>.unmodifiable(_searchProviders);
  SearchProviderConfig? get searchProvider {
    for (final SearchProviderConfig p in _searchProviders) {
      if (p.id == _searchBackendId) return p;
    }
    return _searchProviders.isEmpty ? null : _searchProviders.first;
  }

  String get searchApiKey => searchProvider?.apiKey ?? _searchApiKey;
  String get searchBaseUrl => searchProvider?.baseUrl ?? _searchBaseUrl;
  String get workspaceRoot => _workspaceRoot;
  String get defaultModelKey => _defaultModelKey;
  String? get imageGenModelKey => _imageGenModelKey;
  String? get imageEditModelKey => _imageEditModelKey;

  List<ProviderConfig> get providers =>
      List<ProviderConfig>.unmodifiable(_providers);

  ProviderConfig? providerOf(String id) {
    for (final ProviderConfig p in _providers) {
      if (p.id == id) return p;
    }
    return null;
  }

  /// 全部模型，用户添加的顺序。
  ///
  /// 不过滤"provider 已配好 key"的：过滤掉之后用户在选择器里看不到想用的
  /// 模型，也就不知道该去配哪个 key。选中未配置的由 `createProviderApi`
  /// 报明确的错。
  List<ModelSpec> get models => List<ModelSpec>.unmodifiable(_models);

  ModelSpec? modelByKey(String key) {
    for (final ModelSpec m in _models) {
      if (m.key == key) return m;
    }
    return null;
  }

  List<ModelSpec> modelsOfProvider(String providerId) =>
      _models.where((ModelSpec m) => m.providerId == providerId).toList();

  /// 聊天顶栏的模型选择器按 provider 名分组用这个。
  ///
  /// 空 provider 也保留一个空分组：用户刚加完 provider 还没拉模型时，
  /// 看到自己的 provider 名字在列表里（下面写着"还没有模型"）比它整个
  /// 不出现更好懂。
  List<(ProviderConfig, List<ModelSpec>)> get modelsByProvider {
    return <(ProviderConfig, List<ModelSpec>)>[
      for (final ProviderConfig p in _providers) (p, modelsOfProvider(p.id)),
    ];
  }

  /// 默认模型。没设过或指向已删除的模型时退回第一个。
  ///
  /// 返回 null 表示用户一个模型都没有——界面据此提示去设置页，
  /// 而不是拿一个假模型去发请求。
  ModelSpec? get defaultModel {
    final ModelSpec? saved = modelByKey(_defaultModelKey);
    if (saved != null) return saved;
    return _models.isEmpty ? null : _models.first;
  }

  /// 新建会话和图片工具实际使用的默认模型。设置值失效或尚未写入时，
  /// 与设置页展示保持一致，回退到模型列表第一项。
  String get resolvedDefaultModelKey => defaultModel?.key ?? '';

  List<MemoryEntry> get memories => List<MemoryEntry>.unmodifiable(_memories);

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
    // 不落盘（见 _memories 的说明），所以只通知，不走 _changed()。
    notifyListeners();
  }

  void removeMemory(String id) {
    final int before = _memories.length;
    _memories = _memories.where((MemoryEntry e) => e.id != id).toList();
    if (_memories.length != before) notifyListeners();
  }

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

  /// 查不到就当「询问」的版本，给权限门用（§7-10）。
  ///
  /// [permissionOf] 对未知 id 抛异常是给设置界面用的——那里的 id 是常量，
  /// 拼错了该立刻炸。但权限门查的是工具自报的 id，一个新工具忘了声明
  /// 不该让整轮对话崩掉；退到「询问」既不静默放行，用户也能看见。
  ToolPermission permissionOrAsk(String toolId) {
    return _permissions[toolId] ?? ToolPermission.ask;
  }

  void setThemeMode(ThemeMode mode) {
    if (_themeMode == mode) return;
    _themeMode = mode;
    _changed();
  }

  /// 顶部栏的一键切换：跟随系统时按当前解析结果取反。
  void toggleTheme(Brightness current) {
    setThemeMode(current == Brightness.dark ? ThemeMode.light : ThemeMode.dark);
  }

  void setAccent(AppAccent accent) {
    if (_accent == accent) return;
    _accent = accent;
    _changed();
  }

  void setFontSize(AppFontSize fontSize) {
    if (_fontSize == fontSize) return;
    _fontSize = fontSize;
    _changed();
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
    _changed();
  }

  void setMemoryMode(MemoryMode mode) {
    if (_memoryMode == mode) return;
    _memoryMode = mode;
    _changed();
  }

  /// 用户自定义的 system prompt 追加内容。
  ///
  /// 固定的工作区与记忆规则由 [SessionStore] 始终保留；这里的内容只作为
  /// 追加指令，适合角色、语气和输出格式偏好。
  void setCustomSystemPrompt(String prompt) {
    final String value = prompt.trim().isEmpty ? '' : prompt;
    if (_customSystemPrompt == value) return;
    _customSystemPrompt = value;
    _changed();
  }

  void setAutoCheckUpdates(bool enabled) {
    if (_autoCheckUpdates == enabled) return;
    _autoCheckUpdates = enabled;
    _changed();
  }

  void setDefaultModelKey(String key) {
    if (_defaultModelKey == key) return;
    if (modelByKey(key) == null) {
      throw ArgumentError.value(key, 'key', '没有这个模型');
    }
    _defaultModelKey = key;
    _changed();
  }

  /// 图片生成默认模型，null = 跟随默认模型。
  void setImageGenModel(String? key) {
    if (_imageGenModelKey == key) return;
    if (key != null && modelByKey(key) == null) {
      throw ArgumentError.value(key, 'key', '没有这个模型');
    }
    _imageGenModelKey = key;
    _changed();
  }

  /// 图片编辑默认模型，null = 跟随默认模型。
  void setImageEditModel(String? key) {
    if (_imageEditModelKey == key) return;
    if (key != null && modelByKey(key) == null) {
      throw ArgumentError.value(key, 'key', '没有这个模型');
    }
    _imageEditModelKey = key;
    _changed();
  }

  void setTemperature(double value) {
    if (_temperature == value) return;
    _temperature = value;
    _changed();
  }

  void setSearchBackend(String id) {
    if (_searchBackendId == id) return;
    _searchBackendId = id;
    _changed();
  }

  void addSearchProvider(SearchProviderConfig provider) {
    if (_searchProviders.any((SearchProviderConfig p) => p.id == provider.id))
      return;
    _searchProviders = <SearchProviderConfig>[..._searchProviders, provider];
    _changed();
  }

  void updateSearchProvider(SearchProviderConfig provider) {
    final int index = _searchProviders.indexWhere(
      (SearchProviderConfig p) => p.id == provider.id,
    );
    if (index < 0) return;
    _searchProviders = <SearchProviderConfig>[..._searchProviders]
      ..[index] = provider;
    _changed();
  }

  void removeSearchProvider(String id) {
    final SearchProviderConfig? target = searchProviderById(id);
    if (target == null || target.builtin) return;
    _searchProviders = _searchProviders
        .where((SearchProviderConfig p) => p.id != id)
        .toList();
    if (_searchBackendId == id)
      _searchBackendId = _searchProviders.isEmpty
          ? ''
          : _searchProviders.first.id;
    _changed();
  }

  SearchProviderConfig? searchProviderById(String id) {
    for (final SearchProviderConfig p in _searchProviders) {
      if (p.id == id) return p;
    }
    return null;
  }

  void setSearchConfig({String? apiKey, String? baseUrl}) {
    final String nextKey = apiKey?.trim() ?? _searchApiKey;
    final String nextBase = baseUrl?.trim() ?? _searchBaseUrl;
    if (nextKey == _searchApiKey && nextBase == _searchBaseUrl) return;
    _searchApiKey = nextKey;
    if (nextBase.isNotEmpty) _searchBaseUrl = nextBase;
    final SearchProviderConfig? selected = searchProvider;
    if (selected != null) {
      updateSearchProvider(
        selected.copyWith(
          apiKey: nextKey,
          baseUrl: nextBase.isEmpty ? selected.baseUrl : nextBase,
        ),
      );
      return;
    }
    _changed();
  }

  void setWorkspaceRoot(String path) {
    final String trimmed = path.trim();
    if (trimmed.isEmpty || trimmed == _workspaceRoot) return;
    _workspaceRoot = trimmed;
    _changed();
  }

  // ---- provider 增删改 ----

  /// 加一个 provider，返回它的 id（界面接着要用它拉模型）。
  ProviderConfig addProvider({
    required String displayName,
    required ApiKind apiKind,
    required String baseUrl,
    String apiKey = '',
  }) {
    final ProviderConfig config = ProviderConfig.create(
      displayName: displayName.trim(),
      apiKind: apiKind,
      baseUrl: baseUrl.trim(),
      apiKey: apiKey.trim(),
    );
    _providers = <ProviderConfig>[..._providers, config];
    _changed();
    return config;
  }

  /// 改一个 provider。四个字段一起改是因为界面上它们在同一个表单里，
  /// 分成四个方法会让一次编辑变成四次写盘和四次通知。
  void updateProvider(
    String id, {
    String? displayName,
    ApiKind? apiKind,
    String? baseUrl,
    String? apiKey,
  }) {
    final int index = _providers.indexWhere((ProviderConfig p) => p.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', '未知的 provider');

    final ProviderConfig current = _providers[index];
    final ProviderConfig next = current.copyWith(
      displayName: displayName?.trim(),
      apiKind: apiKind,
      baseUrl: baseUrl?.trim(),
      apiKey: apiKey?.trim(),
    );
    if (next.displayName == current.displayName &&
        next.apiKind == current.apiKind &&
        next.baseUrl == current.baseUrl &&
        next.apiKey == current.apiKey) {
      return;
    }
    _providers = <ProviderConfig>[..._providers]..[index] = next;
    _changed();
  }

  /// 删一个 provider，连带它下面的模型。
  ///
  /// 连带删除是必须的：留下的模型指向一个不存在的 provider，
  /// 在选择器里看着能选，点了必然失败。
  /// 内置 provider 也可以删；删除后会随设置文件保持删除状态。
  void removeProvider(String id) {
    final ProviderConfig? target = providerOf(id);
    if (target == null) return;

    final Set<String> removedKeys = _models
        .where((ModelSpec m) => m.providerId == id)
        .map((ModelSpec m) => m.key)
        .toSet();
    _providers = _providers.where((ProviderConfig p) => p.id != id).toList();
    _models = _models.where((ModelSpec m) => m.providerId != id).toList();
    if (removedKeys.contains(_defaultModelKey)) _defaultModelKey = '';
    if (removedKeys.contains(_imageGenModelKey)) _imageGenModelKey = null;
    if (removedKeys.contains(_imageEditModelKey)) _imageEditModelKey = null;
    _changed();
  }

  // ---- 模型增删改 ----

  /// 加一个模型。同 provider 下 id 重复时忽略——
  /// 用户在 `/models` 拉取之后又手动加同一个是常见操作，不该出现两条。
  /// OpenAI / Anthropic provider 的模型默认开启思考，用户可在详情里关闭。
  ModelSpec? addModel({
    required String providerId,
    required String modelId,
    String? displayName,
    int contextWindow = kDefaultContextWindow,
    int maxOutputTokens = kDefaultMaxOutputTokens,
    ModelCompat compat = const ModelCompat(),
  }) {
    final String trimmed = modelId.trim();
    if (trimmed.isEmpty) return null;
    if (providerOf(providerId) == null) {
      throw ArgumentError.value(providerId, 'providerId', '未知的 provider');
    }

    final ProviderConfig provider = providerOf(providerId)!;
    final ModelCompat effectiveCompat = compat.thinking == ThinkingFormat.none
        ? compat.copyWith(
            thinking: provider.apiKind == ApiKind.anthropicMessages
                ? ThinkingFormat.anthropicThinking
                : ThinkingFormat.openaiReasoningEffort,
          )
        : compat;
    final ModelSpec model = ModelSpec(
      id: trimmed,
      providerId: providerId,
      displayName: displayName?.trim(),
      contextWindow: contextWindow,
      maxOutputTokens: maxOutputTokens,
      compat: effectiveCompat,
    );
    if (modelByKey(model.key) != null) return null;

    _models = <ModelSpec>[..._models, model];
    _changed();
    return model;
  }

  /// 批量加：`/models` 拉回来一串 id 时用。返回真正新增的条数。
  ///
  /// 一次 [_changed] 而不是每个模型一次：拉回 200 个模型不该触发 200 次
  /// 重建和 200 次写盘。
  int addModels({required String providerId, required List<String> modelIds}) {
    if (providerOf(providerId) == null) {
      throw ArgumentError.value(providerId, 'providerId', '未知的 provider');
    }
    final ProviderConfig provider = providerOf(providerId)!;

    final Set<String> existing = _models.map((ModelSpec m) => m.key).toSet();
    final List<ModelSpec> added = <ModelSpec>[];

    for (final String raw in modelIds) {
      final String id = raw.trim();
      if (id.isEmpty) continue;
      final String key = '$providerId/$id';
      if (!existing.add(key)) continue;
      added.add(
        ModelSpec(
          id: id,
          providerId: providerId,
          compat: ModelCompat(
            thinking: provider.apiKind == ApiKind.anthropicMessages
                ? ThinkingFormat.anthropicThinking
                : ThinkingFormat.openaiReasoningEffort,
          ),
        ),
      );
    }

    if (added.isEmpty) return 0;
    _models = <ModelSpec>[..._models, ...added];
    _changed();
    return added.length;
  }

  /// 改模型元数据（显示名、窗口、输出上限、能力标记）。
  void updateModel(
    String key, {
    String? displayName,
    int? contextWindow,
    int? maxOutputTokens,
    ModelCompat? compat,
  }) {
    final int index = _models.indexWhere((ModelSpec m) => m.key == key);
    if (index < 0) throw ArgumentError.value(key, 'key', '没有这个模型');

    _models = <ModelSpec>[..._models]
      ..[index] = _models[index].copyWith(
        displayName: displayName?.trim(),
        contextWindow: contextWindow,
        maxOutputTokens: maxOutputTokens,
        compat: compat,
      );
    _changed();
  }

  void removeModel(String key) {
    final int before = _models.length;
    _models = _models.where((ModelSpec m) => m.key != key).toList();
    if (_models.length == before) return;
    // 删掉的正好是默认模型：清空，让 defaultModel 退回第一个。
    if (_defaultModelKey == key) _defaultModelKey = '';
    // 图片模型指向已删除的模型：回到"跟随默认模型"。
    if (_imageGenModelKey == key) _imageGenModelKey = null;
    if (_imageEditModelKey == key) _imageEditModelKey = null;
    _changed();
  }

  void _changed() {
    notifyListeners();
    _scheduleWrite();
  }

  /// 合并连续变更后再写。
  ///
  /// 温度滑块一次拖动会发几十次通知，每次都写盘等于几十次文件 rename。
  /// 300ms 内的变更合成一次。
  void _scheduleWrite() {
    if (_store == null) return;
    _writeTimer?.cancel();
    _writeTimer = Timer(const Duration(milliseconds: 300), () {
      unawaited(_write());
    });
  }

  Future<void> _write() async {
    final SettingsStore? store = _store;
    if (store == null) return;
    try {
      await store.write(toJson());
      if (_lastWriteError != null) {
        _lastWriteError = null;
        notifyListeners();
      }
    } on Object catch (e) {
      _lastWriteError = e;
      notifyListeners();
    }
  }

  /// 立刻把待写的变更落盘。退出前调用，避免丢掉最后 300ms 内的改动。
  Future<void> flush() async {
    _writeTimer?.cancel();
    _writeTimer = null;
    await _write();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'providers': <Map<String, Object?>>[
      for (final ProviderConfig p in _providers) p.toJson(),
    ],
    'models': <Map<String, Object?>>[
      for (final ModelSpec m in _models) m.toJson(),
    ],
    'defaultModelKey': _defaultModelKey,
    'imageGenModelKey': _imageGenModelKey,
    'imageEditModelKey': _imageEditModelKey,
    'temperature': _temperature,
    'permissions': <String, String>{
      for (final MapEntry<String, ToolPermission> e in _permissions.entries)
        e.key: e.value.name,
    },
    'memoryMode': _memoryMode.name,
    'customSystemPrompt': _customSystemPrompt,
    'autoCheckUpdates': _autoCheckUpdates,
    'searchBackendId': _searchBackendId,
    'searchApiKey': _searchApiKey,
    'searchBaseUrl': _searchBaseUrl,
    'searchProviders': <Map<String, Object?>>[
      for (final SearchProviderConfig p in _searchProviders) p.toJson(),
    ],
    'workspaceRoot': _workspaceRoot,
    'themeMode': _themeMode.name,
    'accent': _accent.name,
    'fontSize': _fontSize.name,
  };

  /// 从 WebDAV 备份恢复非偏好设置。偏好（主题、字体、权限等）刻意保留。
  Future<void> importPortableConfig(Map<String, Object?> json) async {
    final List<ProviderConfig> providers = _readProviders(json['providers']);
    final List<ModelSpec> models = _readModels(json['models']);
    final List<SearchProviderConfig> searchProviders = _readSearchProviders(
      json['searchProviders'],
    );
    if (models.any(
          (ModelSpec m) =>
              providers.every((ProviderConfig p) => p.id != m.providerId),
        )) {
      throw const FormatException('备份中的提供商或模型配置无效');
    }
    _providers = providers;
    _models = models;
    if (searchProviders.isNotEmpty) _searchProviders = searchProviders;
    _defaultModelKey = json['defaultModelKey'] as String? ?? '';
    _imageGenModelKey = json['imageGenModelKey'] as String?;
    _imageEditModelKey = json['imageEditModelKey'] as String?;
    _searchBackendId = json['searchBackendId'] as String? ?? '';
    _changed();
    await flush();
  }

  @override
  void dispose() {
    _writeTimer?.cancel();
    super.dispose();
  }
}
