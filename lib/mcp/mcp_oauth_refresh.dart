import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'mcp_oauth.dart';

/// 刷新失败。上层据此清除已失效的令牌并提示用户重新登录。
final class McpOAuthRefreshFailure implements Exception {
  const McpOAuthRefreshFailure(this.message);
  final String message;

  @override
  String toString() => message;
}

/// 用 `refresh_token` 换取新的访问令牌。
///
/// SDK 把"返回一个可用令牌"的责任交给 provider，自己不做刷新；这一段在这里
/// 补齐。令牌端点不落盘，按 issuer 重做一次授权服务器元数据发现（RFC 8414 +
/// OpenID Connect Discovery 1.0，探测顺序与 SDK 一致）。
///
/// 客户端认证方式按 RFC 8414 的默认值处理：有 client_secret 用
/// `client_secret_basic`，没有就用 `none`。机密客户端由服务器直接拒绝不合规
/// 的请求，不需要在这里猜更多方法。
final class McpOAuthRefresher {
  const McpOAuthRefresher();

  /// 刷新超时。刷新发生在一次工具调用之前，不能无限等待。
  static const Duration defaultTimeout = Duration(seconds: 20);

  Future<McpOAuthTokenSet> refresh(
    McpOAuthTokenSet current, {
    String? clientSecret,
    http.Client? client,
    Duration timeout = defaultTimeout,
  }) async {
    final String? refreshToken = current.refreshToken;
    final String? clientId = current.clientId;
    if (refreshToken == null || clientId == null) {
      throw const McpOAuthRefreshFailure('缺少刷新令牌或客户端标识，需要重新登录');
    }
    final http.Client active = client ?? http.Client();
    try {
      final Uri endpoint = await _discoverTokenEndpoint(
        Uri.parse(current.issuer),
        active,
        timeout,
      );
      return await _exchange(
        endpoint,
        current,
        refreshToken: refreshToken,
        clientId: clientId,
        clientSecret: clientSecret,
        client: active,
        timeout: timeout,
      );
    } on McpOAuthRefreshFailure {
      rethrow;
    } on Object catch (error) {
      throw McpOAuthRefreshFailure('刷新令牌请求失败：${_safe(error)}');
    } finally {
      if (client == null) active.close();
    }
  }

  Future<Uri> _discoverTokenEndpoint(
    Uri issuer,
    http.Client client,
    Duration timeout,
  ) async {
    for (final Uri candidate in _metadataCandidates(issuer)) {
      final http.Response response;
      try {
        response = await client
            .get(candidate, headers: const <String, String>{
              'Accept': 'application/json',
            })
            .timeout(timeout);
      } on Object {
        // 探测式发现：某个候选端点不可达不代表整轮发现失败。
        continue;
      }
      if (response.statusCode != 200) continue;
      final Object? json = _decode(response.body);
      if (json is! Map<String, Object?>) continue;
      final Object? endpoint = json['token_endpoint'];
      if (endpoint is! String || endpoint.isEmpty) continue;
      final Uri? uri = Uri.tryParse(endpoint);
      if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
        throw const McpOAuthRefreshFailure('授权服务器返回的令牌端点无效');
      }
      if (uri.scheme == 'http' && !_isLoopback(uri.host)) {
        throw const McpOAuthRefreshFailure('授权服务器返回了不安全的令牌端点');
      }
      return uri;
    }
    throw const McpOAuthRefreshFailure('无法从 issuer 发现令牌端点，需要重新登录');
  }

  Future<McpOAuthTokenSet> _exchange(
    Uri endpoint,
    McpOAuthTokenSet current, {
    required String refreshToken,
    required String clientId,
    required String? clientSecret,
    required http.Client client,
    required Duration timeout,
  }) async {
    final Map<String, String> headers = <String, String>{
      'Accept': 'application/json',
      'Content-Type': 'application/x-www-form-urlencoded',
    };
    final Map<String, String> body = <String, String>{
      'grant_type': 'refresh_token',
      'refresh_token': refreshToken,
      'client_id': clientId,
      // RFC 8707：令牌请求必须带上它要被使用的目标资源。
      'resource': current.resource.toString(),
    };
    if (clientSecret != null) {
      headers['Authorization'] = 'Basic ${base64Encode(utf8.encode('$clientId:$clientSecret'))}';
    }

    final http.Response response = await client
        .post(endpoint, headers: headers, body: body)
        .timeout(timeout);
    if (response.statusCode != 200) {
      throw McpOAuthRefreshFailure('令牌端点返回 HTTP ${response.statusCode}，需要重新登录');
    }
    final Object? json = _decode(response.body);
    if (json is! Map<String, Object?>) {
      throw const McpOAuthRefreshFailure('令牌端点返回的不是 JSON 对象');
    }
    final Object? accessToken = json['access_token'];
    if (accessToken is! String || accessToken.isEmpty) {
      throw const McpOAuthRefreshFailure('令牌端点没有返回访问令牌');
    }
    final Object? refresh = json['refresh_token'];
    final Object? expiresIn = json['expires_in'];
    final Object? scope = json['scope'];
    return current.copyWith(
      accessToken: accessToken,
      // 轮换后的刷新令牌必须覆盖旧值；服务器未返回时沿用原值。
      refreshToken: refresh is String && refresh.isNotEmpty ? refresh : null,
      expiresAt: expiresIn is num && expiresIn > 0
          ? DateTime.now().add(Duration(seconds: expiresIn.toInt()))
          : null,
      scope: scope is String ? scope : null,
    );
  }

  List<Uri> _metadataCandidates(Uri issuer) {
    final String issuerPath = issuer.path;
    final String pathPrefix = issuerPath.isEmpty || issuerPath == '/'
        ? ''
        : issuerPath.endsWith('/')
        ? issuerPath.substring(0, issuerPath.length - 1)
        : issuerPath;
    final List<Uri> candidates = <Uri>[
      _discoveryUri(issuer, '/.well-known/oauth-authorization-server$pathPrefix'),
      _discoveryUri(issuer, '/.well-known/openid-configuration$pathPrefix'),
      if (pathPrefix.isNotEmpty)
        _discoveryUri(issuer, '$pathPrefix/.well-known/openid-configuration'),
      if (pathPrefix.isNotEmpty)
        _discoveryUri(
          issuer,
          '$pathPrefix/.well-known/oauth-authorization-server',
        ),
    ];
    final Set<String> seen = <String>{};
    return <Uri>[
      for (final Uri candidate in candidates)
        if (seen.add(candidate.toString())) candidate,
    ];
  }

  Uri _discoveryUri(Uri issuer, String path) => Uri(
    scheme: issuer.scheme,
    host: issuer.host,
    port: issuer.hasPort ? issuer.port : null,
    path: path,
  );

  static Object? _decode(String body) {
    try {
      return jsonDecode(body);
    } on FormatException {
      return null;
    }
  }

  static bool _isLoopback(String host) {
    final String normalized = host.toLowerCase();
    return normalized == 'localhost' ||
        normalized == '::1' ||
        normalized.startsWith('127.');
  }

  static String _safe(Object error) {
    if (error is TimeoutException) return '请求超时';
    if (error is http.ClientException) return '网络不可达';
    if (error is FormatException) return '响应格式无效';
    // 不把异常原文带出去：请求异常可能包含完整 URL 或凭据。
    return error.runtimeType.toString();
  }
}
