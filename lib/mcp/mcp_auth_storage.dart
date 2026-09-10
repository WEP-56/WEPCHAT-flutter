import 'mcp_oauth.dart';

/// OAuth 令牌的内存持有者与序列化。
///
/// 读取是同步的（SDK 在每次请求前调用 `tokens()`），写入只改内存并回调通知
/// 宿主落盘。宿主是 [AppSettings]，令牌与服务器配置共用 `settings.json` 但走
/// 独立的 `mcpAuth` 键——见 `AppSettings.mcpAuth` 的说明。
final class McpAuthStorage implements McpAuthStore {
  McpAuthStorage({
    Map<String, McpOAuthTokenSet> initial = const <String, McpOAuthTokenSet>{},
    this.onChanged,
  }) : _tokens = Map<String, McpOAuthTokenSet>.of(initial);

  /// 每次令牌变化后调用。由宿主接到设置写盘与界面刷新上。
  void Function()? onChanged;

  final Map<String, McpOAuthTokenSet> _tokens;

  @override
  McpOAuthTokenSet? tokenSet(String serverId) => _tokens[serverId];

  @override
  Future<void> saveTokenSet(String serverId, McpOAuthTokenSet? tokens) {
    if (tokens == null) {
      remove(serverId);
      return Future<void>.value();
    }
    _tokens[serverId] = tokens;
    onChanged?.call();
    return Future<void>.value();
  }

  /// 删除服务器配置时一并清掉它的凭据，避免留下无人认领的令牌。
  void remove(String serverId) {
    if (_tokens.remove(serverId) == null) return;
    onChanged?.call();
  }

  Map<String, Object?> toJson() => <String, Object?>{
    for (final MapEntry<String, McpOAuthTokenSet> entry in _tokens.entries)
      entry.key: entry.value.toJson(),
  };

  /// 解析不了的记录按"未登录"处理。
  ///
  /// 与其它设置项的解析约定一致（见 `_readPermissions`）：一条损坏的凭据记录
  /// 不该让整个设置加载失败，但也不能被当成有效授权继续发请求。
  static Map<String, McpOAuthTokenSet> decode(Object? raw) {
    if (raw is! Map<String, Object?>) {
      return <String, McpOAuthTokenSet>{};
    }
    final Map<String, McpOAuthTokenSet> tokens = <String, McpOAuthTokenSet>{};
    for (final MapEntry<String, Object?> entry in raw.entries) {
      final McpOAuthTokenSet? parsed = McpOAuthTokenSet.fromJson(entry.value);
      if (parsed != null) tokens[entry.key] = parsed;
    }
    return tokens;
  }
}
