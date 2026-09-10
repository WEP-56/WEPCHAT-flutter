import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart' as sdk;

import 'mcp_config.dart';
import 'mcp_connection.dart';
import 'mcp_oauth.dart';
import 'mcp_oauth_refresh.dart';

/// 令牌读取与刷新。授权码流程与会话内只读两种 provider 共用这一份实现，
/// 避免"什么时候该刷新"出现两套判断。
final class McpTokenSource {
  McpTokenSource({
    required this.serverId,
    required this.client,
    required this.store,
    this.refresher = const McpOAuthRefresher(),
    http.Client? httpClient,
  }) : _httpClient = httpClient;

  final String serverId;
  final McpOAuthClient client;
  final McpAuthStore store;
  final McpOAuthRefresher refresher;
  final http.Client? _httpClient;

  Future<sdk.OAuthTokens?> tokens() async {
    final McpOAuthTokenSet? stored = store.tokenSet(serverId);
    if (stored == null) return null;
    if (!stored.isExpired(DateTime.now())) return toSdkTokens(stored);
    if (!stored.canRefresh) {
      // 没有刷新令牌就不猜：交回 null，让调用方回到"需要重新授权"。
      return null;
    }
    try {
      final McpOAuthTokenSet refreshed = await refresher.refresh(
        stored,
        clientSecret: client.clientSecret,
        client: _httpClient,
      );
      await store.saveTokenSet(serverId, refreshed);
      return toSdkTokens(refreshed);
    } on McpOAuthRefreshFailure {
      // 刷新失败说明当前令牌已经不可用。清除它，让状态回到"需要重新登录"，
      // 而不是拿着一个必然被拒绝的令牌反复请求服务器。
      await store.saveTokenSet(serverId, null);
      return null;
    }
  }

  /// 交回带绑定信息的子类，SDK 会用它校验令牌没有被换到别的授权服务器或
  /// 受保护资源上。
  static sdk.OAuthTokens toSdkTokens(McpOAuthTokenSet set) =>
      sdk.OAuthIssuerBoundAuthorizationCodeTokens(
        accessToken: set.accessToken,
        refreshToken: set.refreshToken,
        scope: set.scope,
        authorizationServerIssuer: set.issuer,
        resource: set.resource,
      );
}

/// 聊天轮次使用的 provider：只读令牌，绝不发起跳转。
///
/// 没有可用令牌时直接失败并提示用户去设置里登录，而不是在对话中途弹出浏览器
/// ——授权必须由用户主动发起，这条约束在连接层强制执行。
final class McpTokenOnlyProvider implements sdk.OAuthClientProvider {
  McpTokenOnlyProvider({required McpTokenSource tokens}) : _tokens = tokens;

  final McpTokenSource _tokens;

  @override
  Future<sdk.OAuthTokens?> tokens() => _tokens.tokens();

  @override
  Future<void> redirectToAuthorization() {
    throw const McpFailure('尚未登录授权：请在「设置 → 高级功能」中点击该服务器的「登录授权」');
  }
}

/// 「登录授权」使用的 provider：实现 SDK 的授权码流程。
///
/// 协议部分全部由 SDK 完成：解析 `WWW-Authenticate` 挑战、受保护资源元数据
/// 发现（RFC 9728）、授权服务器发现（RFC 8414 + OpenID Connect Discovery）、
/// PKCE S256、`state`/`iss` 校验和授权码交换。本类只负责三件事：
///
/// 1. 每次请求前给出可用令牌，过期时先静默刷新；
/// 2. 把待跳转的授权地址交给上层（由上层确认授权域名后再打开浏览器）；
/// 3. 保存换取到的令牌及其绑定信息。
final class McpOAuthProvider implements sdk.OAuthAuthorizationCodeProvider {
  McpOAuthProvider({
    required McpTokenSource tokens,
    required this.redirectUri,
    required this.onAuthorizationUri,
  }) : _tokens = tokens;

  final McpTokenSource _tokens;

  /// 回环回调地址。SDK 只接受 HTTPS 或 loopback HTTP。
  @override
  final Uri redirectUri;

  /// 上层在此确认并打开浏览器。实现方只需"发起跳转"，不必等用户完成授权：
  /// SDK 会在调用返回后立刻抛出 `UnauthorizedError`。
  final Future<void> Function(Uri authorizationUri) onAuthorizationUri;

  /// 授权重定向里带回的 client_id。
  ///
  /// 动态注册和 Client ID Metadata Document 的客户端标识只在这里出现，刷新
  /// 令牌时要用它，所以在 [saveTokens] 时一并落盘。
  String? _pendingClientId;

  @override
  String get clientId => _tokens.client.clientId;

  @override
  String? get clientSecret => _tokens.client.clientSecret;

  @override
  List<String> get scopes => _tokens.client.scopes;

  @override
  Future<sdk.OAuthTokens?> tokens() => _tokens.tokens();

  @override
  Future<void> redirectToAuthorizationUrl(Uri authorizationUri) async {
    _pendingClientId = authorizationUri.queryParameters['client_id'];
    await onAuthorizationUri(authorizationUri);
  }

  @override
  Future<void> redirectToAuthorization() {
    // 授权码 provider 的 SDK 路径只会调用 redirectToAuthorizationUrl。这里被
    // 调用说明接线错了，直接失败，不静默放行一个未授权的请求。
    throw const McpFailure('OAuth 授权流程未按授权码方式发起');
  }

  @override
  Future<void> saveTokens(sdk.OAuthTokens tokens) async {
    if (tokens is! sdk.OAuthIssuerBoundAuthorizationCodeTokens) {
      // 授权码流程里 SDK 只会发送带绑定信息的子类。缺少 issuer/resource 就
      // 无法安全保存，明确失败好过存下一个会被自己拒绝的令牌。
      throw const McpFailure('授权服务器没有返回令牌绑定信息，无法保存令牌');
    }
    final int? expiresIn = tokens.expiresIn;
    final String configuredClientId = _tokens.client.clientId;
    await _tokens.store.saveTokenSet(
      _tokens.serverId,
      McpOAuthTokenSet(
        accessToken: tokens.accessToken,
        refreshToken: tokens.refreshToken,
        expiresAt: expiresIn == null
            ? null
            : DateTime.now().add(Duration(seconds: expiresIn)),
        issuer: tokens.authorizationServerIssuer,
        resource: tokens.resource,
        clientId: _pendingClientId ?? (configuredClientId.isEmpty ? null : configuredClientId),
        scope: tokens.scope,
      ),
    );
  }
}
