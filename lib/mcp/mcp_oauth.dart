/// OAuth 授权结果的领域表示与存储契约。
///
/// MCP 授权章节要求客户端把访问令牌绑定到签发它的授权服务器和它被授权的
/// 受保护资源，并拒绝把令牌发往其他目标。SDK 用这些字段做校验，所以存储里
/// 必须留下它们，不能只存一个裸的 access token。
///
/// OAuth 属于应用私有凭据。它只落在 App 私有 `settings.json`，不进入 WebDAV
/// 可移植备份，也不会随着会话工作区一起被复制。
final class McpOAuthTokenSet {
  McpOAuthTokenSet({
    required this.accessToken,
    required this.issuer,
    required this.resource,
    this.refreshToken,
    this.expiresAt,
    this.clientId,
    this.scope,
  }) {
    if (accessToken.isEmpty) {
      throw const FormatException('OAuth 访问令牌不能为空');
    }
    final Uri? issuerUri = Uri.tryParse(issuer);
    if (issuerUri == null ||
        !issuerUri.hasScheme ||
        issuerUri.host.isEmpty ||
        issuerUri.hasFragment) {
      throw const FormatException('OAuth 授权服务器标识必须是绝对 HTTP(S) URI');
    }
    if (!resource.hasScheme || resource.host.isEmpty) {
      throw const FormatException('OAuth 受保护资源必须是绝对 URI');
    }
    if (refreshToken != null && refreshToken!.isEmpty) {
      throw const FormatException('OAuth 刷新令牌不能是空字符串');
    }
    if (clientId != null && clientId!.isEmpty) {
      throw const FormatException('OAuth client_id 不能是空字符串');
    }
  }

  final String accessToken;
  final String? refreshToken;

  /// 令牌到期时刻。服务器未返回 `expires_in` 时为 null，此时按"未过期"处理，
  /// 由服务器用 401 决定是否需要重新授权。
  final DateTime? expiresAt;

  /// 授权服务器 issuer 标识，来自受保护资源元数据。
  final String issuer;

  /// 令牌被授权的受保护资源。
  final Uri resource;

  /// 授权时实际使用的客户端标识。
  ///
  /// 动态注册与 Client ID Metadata Document 的结果只出现在授权重定向里，
  /// 刷新令牌时必须带上它，所以要在保存令牌时一起记下来。
  final String? clientId;

  /// 授权服务器返回的 scope 原文。
  final String? scope;

  /// 到期前 30 秒即视为过期，避免请求在途中失效。
  bool isExpired(DateTime now) {
    final DateTime? expiry = expiresAt;
    return expiry != null &&
        !now.add(const Duration(seconds: 30)).isBefore(expiry);
  }

  /// 是否具备静默刷新的全部条件。缺 clientId 时只能重新走一次授权。
  bool get canRefresh =>
      (refreshToken?.isNotEmpty ?? false) && (clientId?.isNotEmpty ?? false);

  McpOAuthTokenSet copyWith({
    String? accessToken,
    String? refreshToken,
    DateTime? expiresAt,
    String? clientId,
    String? scope,
  }) => McpOAuthTokenSet(
    accessToken: accessToken ?? this.accessToken,
    refreshToken: refreshToken ?? this.refreshToken,
    expiresAt: expiresAt ?? this.expiresAt,
    issuer: issuer,
    resource: resource,
    clientId: clientId ?? this.clientId,
    scope: scope ?? this.scope,
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'accessToken': accessToken,
    if (refreshToken != null) 'refreshToken': refreshToken,
    if (expiresAt != null) 'expiresAt': expiresAt!.toIso8601String(),
    'issuer': issuer,
    'resource': resource.toString(),
    if (clientId != null) 'clientId': clientId,
    if (scope != null) 'scope': scope,
  };

  /// 结构不完整时返回 null，调用方按"未登录"处理即可。
  ///
  /// 这与其它设置项的解析约定一致（见 `_readPermissions`）：一条损坏的凭据
  /// 记录不该让整个设置加载失败，但也不能被当成有效授权继续使用。
  static McpOAuthTokenSet? fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) return null;
    final Object? accessToken = raw['accessToken'];
    final Object? issuer = raw['issuer'];
    final Object? resource = raw['resource'];
    if (accessToken is! String || accessToken.isEmpty) return null;
    if (issuer is! String || issuer.isEmpty) return null;
    if (resource is! String) return null;
    final Uri? resourceUri = Uri.tryParse(resource);
    if (resourceUri == null ||
        !resourceUri.hasScheme ||
        resourceUri.host.isEmpty) {
      return null;
    }
    return McpOAuthTokenSet(
      accessToken: accessToken,
      issuer: issuer,
      resource: resourceUri,
      refreshToken: _optionalString(raw, 'refreshToken'),
      clientId: _optionalString(raw, 'clientId'),
      scope: _optionalString(raw, 'scope'),
      expiresAt: switch (raw['expiresAt']) {
        final String value => DateTime.tryParse(value),
        _ => null,
      },
    );
  }
}

String? _optionalString(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  return value is String && value.isNotEmpty ? value : null;
}

/// OAuth 令牌的同步读、异步写入口。
///
/// 读取必须同步：SDK 在每次请求前调用 `tokens()`，那里没有等待 IO 的位置。
abstract interface class McpAuthStore {
  /// 该服务器当前保存的令牌。未登录或被判定失效时返回 null。
  McpOAuthTokenSet? tokenSet(String serverId);

  /// [tokens] 传 null 表示清除（退出登录，或刷新失败后要求重新授权）。
  Future<void> saveTokenSet(String serverId, McpOAuthTokenSet? tokens);
}
