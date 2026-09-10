import '../tools/tool_permission.dart';

const int kMcpMaxServers = 16;
const int kMcpMaxTools = 256;
const int kMcpMinTimeoutSeconds = 1;
const int kMcpMaxTimeoutSeconds = 600;
const Duration kMcpDefaultTimeout = Duration(seconds: 60);
const int kMcpMaxMessageBytes = 8 * 1024 * 1024;
const int kMcpMaxSchemaBytes = 128 * 1024;
const int kMcpMaxToolPages = 32;
const String kMcpPermissionPrefix = 'mcp:';
const String kMcpBoundaryNotice =
    'MCP 相关工具由外部服务器执行，不受 WePChat 工作区门禁限制。'
    '本地服务器可能访问工作区外的文件并运行程序；远程服务器可能访问或修改外部服务数据。'
    '请仅连接你信任的服务器。工具调用仍遵循下方的权限设置。';

enum McpTransportKind {
  streamableHttp('Streamable HTTP'),
  sse('SSE（旧版 HTTP + SSE）'),
  stdio('stdio（Windows 本地）');

  const McpTransportKind(this.label);
  final String label;
}

/// 远端 MCP 的认证方式。
///
/// OAuth 登录依赖 SDK 的授权码流程，只有 Streamable HTTP 传输暴露该入口；
/// 旧式 SSE 传输只支持固定请求头。
enum McpRemoteAuth {
  headers('固定请求头'),
  oauth('OAuth 登录');

  const McpRemoteAuth(this.label);
  final String label;
}

/// OAuth 客户端信息。
///
/// [clientId] 留空时交给 SDK 按协议顺序尝试 Client ID Metadata Document 和
/// 动态客户端注册（RFC 7591）；服务器要求预注册客户端时再填写。
final class McpOAuthClient {
  McpOAuthClient({
    this.clientId = '',
    this.clientSecret,
    Iterable<String> scopes = const <String>[],
    this.callbackPort,
  }) : scopes = List<String>.unmodifiable(scopes) {
    if (clientId.contains(_oauthUnsafe)) {
      throw const FormatException('OAuth client_id 不能包含空白字符');
    }
    final String? secret = clientSecret;
    if (secret != null && (secret.isEmpty || secret.contains(_oauthUnsafe))) {
      throw const FormatException('OAuth client_secret 必须是非空且不含空白字符的字符串');
    }
    if (scopes.any(
      (String scope) => scope.isEmpty || scope.contains(_oauthUnsafe),
    )) {
      throw const FormatException('OAuth scope 必须是不含空白的单个标识符');
    }
    final int? port = callbackPort;
    if (port != null && (port < 1024 || port > 65535)) {
      throw const FormatException('OAuth 回调端口必须在 1024–65535 之间');
    }
  }

  factory McpOAuthClient.fromJson(Object? raw) {
    if (raw == null) return McpOAuthClient();
    if (raw is! Map<String, Object?>) {
      throw const FormatException('OAuth 客户端配置必须是 JSON 对象');
    }
    final Object? port = raw['callbackPort'];
    if (port != null && port is! int) {
      throw const FormatException('OAuth 回调端口必须是整数');
    }
    return McpOAuthClient(
      clientId: switch (raw['clientId']) {
        null => '',
        final String value => value,
        _ => throw const FormatException('OAuth client_id 必须是字符串'),
      },
      clientSecret: switch (raw['clientSecret']) {
        null => null,
        final String value => value,
        _ => throw const FormatException('OAuth client_secret 必须是字符串'),
      },
      scopes: _stringList(raw['scopes'], 'scopes'),
      callbackPort: port as int?,
    );
  }

  /// 空字符串表示未预注册，交给 SDK 自动注册。
  final String clientId;
  final String? clientSecret;
  final List<String> scopes;

  /// 回环回调端口。留空使用系统分配的临时端口。
  final int? callbackPort;

  Map<String, Object?> toJson() => <String, Object?>{
    'clientId': clientId,
    if (clientSecret != null) 'clientSecret': clientSecret,
    'scopes': scopes,
    if (callbackPort != null) 'callbackPort': callbackPort,
  };
}

final RegExp _oauthUnsafe = RegExp(r'[\s\x00]');

/// Transport-specific configuration; credentials remain in App-private settings.
sealed class McpEndpoint {
  const McpEndpoint();
  McpTransportKind get kind;
  Map<String, Object?> toJson();

  static McpEndpoint fromJson(Map<String, Object?> json) {
    final String transport = _string(json, 'transport');
    return switch (transport) {
      'streamableHttp' || 'sse' => McpRemoteEndpoint(
        kind: transport == 'sse'
            ? McpTransportKind.sse
            : McpTransportKind.streamableHttp,
        url: Uri.parse(_string(json, 'url')),
        headers: _stringMap(json['headers'], 'headers'),
        auth: _remoteAuth(json),
        oauth: json['oauth'] == null
            ? null
            : McpOAuthClient.fromJson(json['oauth']),
      ),
      'stdio' => McpStdioEndpoint(
        command: _string(json, 'command'),
        arguments: _stringList(json['arguments'], 'arguments'),
        environment: _stringMap(json['environment'], 'environment'),
        workingDirectory: switch (json['workingDirectory']) {
          null => null,
          final String value when value.trim().isNotEmpty => value,
          _ => throw const FormatException('workingDirectory 必须是非空字符串'),
        },
      ),
      _ => throw FormatException('不支持的 MCP 传输类型：$transport'),
    };
  }
}

McpRemoteAuth _remoteAuth(Map<String, Object?> json) {
  final String name = _string(json, 'auth', defaultValue: 'headers');
  return switch (name) {
    'headers' => McpRemoteAuth.headers,
    'oauth' => McpRemoteAuth.oauth,
    _ => throw FormatException('不支持的 MCP 认证方式：$name'),
  };
}

final class McpRemoteEndpoint extends McpEndpoint {
  McpRemoteEndpoint({
    required this.kind,
    required this.url,
    Map<String, String> headers = const <String, String>{},
    this.auth = McpRemoteAuth.headers,
    this.oauth,
  }) : headers = Map<String, String>.unmodifiable(headers) {
    if (kind == McpTransportKind.stdio) {
      throw const FormatException('网络 MCP 不能使用 stdio');
    }
    if (!<String>{'http', 'https'}.contains(url.scheme) ||
        url.host.isEmpty ||
        url.userInfo.isNotEmpty ||
        url.hasFragment) {
      throw const FormatException('请填写有效的 HTTP/HTTPS 地址，凭据请放入请求头');
    }
    final Set<String> names = <String>{};
    for (final MapEntry<String, String> entry in headers.entries) {
      if (entry.key.isEmpty ||
          RegExp(r'[\s:]').hasMatch(entry.key) ||
          RegExp(r'[\r\n\x00]').hasMatch(entry.value) ||
          !names.add(entry.key.toLowerCase())) {
        throw const FormatException('请求头名称无效、重复，或值含有换行');
      }
    }
    if (auth != McpRemoteAuth.oauth) return;
    if (kind != McpTransportKind.streamableHttp) {
      throw const FormatException('只有 Streamable HTTP 支持 OAuth 登录；SSE 请使用固定请求头');
    }
    if (oauth == null) {
      throw const FormatException('OAuth 登录缺少客户端配置');
    }
    if (names.contains('authorization')) {
      throw const FormatException('OAuth 登录会自行设置 Authorization 头，请从请求头中移除');
    }
  }

  @override
  final McpTransportKind kind;
  final Uri url;
  final Map<String, String> headers;
  final McpRemoteAuth auth;

  /// 仅在 [auth] 为 OAuth 时有意义。
  final McpOAuthClient? oauth;

  /// OAuth 客户端配置；非 OAuth 端点返回 null，调用方无需再判认证方式。
  McpOAuthClient? get oauthClient =>
      auth == McpRemoteAuth.oauth ? oauth : null;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'transport': kind.name,
    'url': url.toString(),
    'auth': auth.name,
    'headers': headers,
    if (oauthClient != null) 'oauth': oauthClient!.toJson(),
  };
}

final class McpStdioEndpoint extends McpEndpoint {
  McpStdioEndpoint({
    required this.command,
    List<String> arguments = const <String>[],
    Map<String, String> environment = const <String, String>{},
    this.workingDirectory,
  }) : arguments = List<String>.unmodifiable(arguments),
       environment = Map<String, String>.unmodifiable(environment) {
    if (command.trim().isEmpty || command.contains('\u0000')) {
      throw const FormatException('请填写可执行文件，例如 npx 或 uvx');
    }
    if (arguments.any((String value) => value.contains('\u0000')) ||
        environment.entries.any(
          (MapEntry<String, String> entry) =>
              entry.key.isEmpty ||
              entry.key.contains('=') ||
              '${entry.key}${entry.value}'.contains('\u0000'),
        ) ||
        (workingDirectory != null &&
            (workingDirectory!.trim().isEmpty ||
                workingDirectory!.contains('\u0000')))) {
      throw const FormatException('MCP 启动参数、环境变量或工作目录无效');
    }
  }

  @override
  McpTransportKind get kind => McpTransportKind.stdio;
  final String command;
  final List<String> arguments;
  final Map<String, String> environment;
  final String? workingDirectory;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'transport': kind.name,
    'command': command,
    'arguments': arguments,
    'environment': environment,
    if (workingDirectory != null) 'workingDirectory': workingDirectory,
  };
}

final class McpServerConfig {
  McpServerConfig({
    required this.id,
    required this.name,
    required this.endpoint,
    this.enabled = true,
    this.permission = ToolPermission.ask,
    this.timeout = kMcpDefaultTimeout,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('MCP server ID 必须是 1–64 位字母、数字、下划线或连字符');
    }
    if (name.trim().isEmpty || name.length > 100) {
      throw const FormatException('MCP 名称必须是 1–100 个字符');
    }
    if (timeout.inSeconds < kMcpMinTimeoutSeconds ||
        timeout.inSeconds > kMcpMaxTimeoutSeconds) {
      throw const FormatException('MCP 超时必须在 1–600 秒之间');
    }
  }

  factory McpServerConfig.fromJson(Object? raw) {
    if (raw is! Map<String, Object?>) {
      throw const FormatException('MCP server 配置必须是 JSON 对象');
    }
    final String permissionName = _string(
      raw,
      'permission',
      defaultValue: 'ask',
    );
    final ToolPermission permission = switch (permissionName) {
      'ask' => ToolPermission.ask,
      'allowed' => ToolPermission.allowed,
      'denied' => ToolPermission.denied,
      _ => throw const FormatException('MCP 工具权限无效'),
    };
    final Object? seconds = raw['timeoutSeconds'];
    if (seconds != null && seconds is! int) {
      throw const FormatException('MCP 超时必须是整数秒');
    }
    return McpServerConfig(
      id: _string(raw, 'id'),
      name: _string(raw, 'name'),
      endpoint: McpEndpoint.fromJson(raw),
      enabled: _bool(raw, 'enabled', true),
      permission: permission,
      timeout: seconds == null
          ? kMcpDefaultTimeout
          : Duration(seconds: seconds as int),
    );
  }

  final String id;
  final String name;
  final McpEndpoint endpoint;
  final bool enabled;
  final ToolPermission permission;
  final Duration timeout;
  String get permissionId => '$kMcpPermissionPrefix$id';

  McpServerConfig copyWith({bool? enabled, ToolPermission? permission}) =>
      McpServerConfig(
        id: id,
        name: name,
        endpoint: endpoint,
        enabled: enabled ?? this.enabled,
        permission: permission ?? this.permission,
        timeout: timeout,
      );

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'name': name,
    'enabled': enabled,
    'permission': permission.name,
    'timeoutSeconds': timeout.inSeconds,
    ...endpoint.toJson(),
  };
}

final class McpSettings {
  McpSettings({
    this.enabled = false,
    Iterable<McpServerConfig> servers = const [],
  }) : servers = List<McpServerConfig>.unmodifiable(servers) {
    if (this.servers.length > kMcpMaxServers) {
      throw const FormatException('最多配置 16 个 MCP server');
    }
    if (this.servers
            .map((McpServerConfig server) => server.id)
            .toSet()
            .length !=
        this.servers.length) {
      throw const FormatException('MCP server ID 重复');
    }
  }

  factory McpSettings.fromJson(Object? raw) {
    if (raw == null) return McpSettings(); // Existing installs start disabled.
    if (raw is! Map<String, Object?> || raw['servers'] is! List<Object?>) {
      throw const FormatException('MCP 设置无效：servers 必须是数组');
    }
    return McpSettings(
      enabled: _bool(raw, 'enabled', false),
      servers: (raw['servers']! as List<Object?>).map(McpServerConfig.fromJson),
    );
  }

  final bool enabled;
  final List<McpServerConfig> servers;

  McpServerConfig? server(String id) {
    for (final McpServerConfig server in servers) {
      if (server.id == id) return server;
    }
    return null;
  }

  Map<String, Object?> toJson() => <String, Object?>{
    'enabled': enabled,
    'servers': servers
        .map((McpServerConfig server) => server.toJson())
        .toList(),
  };
}

String _string(Map<String, Object?> json, String key, {String? defaultValue}) {
  final Object? value = json[key];
  if (value == null && defaultValue != null) return defaultValue;
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('MCP $key 必须是非空字符串');
  }
  return value;
}

bool _bool(Map<String, Object?> json, String key, bool defaultValue) {
  final Object? value = json[key];
  if (value == null) return defaultValue;
  if (value is! bool) throw FormatException('MCP $key 必须是布尔值');
  return value;
}

List<String> _stringList(Object? raw, String key) {
  if (raw == null) return const <String>[];
  if (raw is! List<Object?> || raw.any((Object? value) => value is! String)) {
    throw FormatException('MCP $key 必须是字符串数组');
  }
  return raw.cast<String>();
}

Map<String, String> _stringMap(Object? raw, String key) {
  if (raw == null) return const <String, String>{};
  if (raw is! Map<String, Object?> ||
      raw.values.any((Object? value) => value is! String)) {
    throw FormatException('MCP $key 必须是字符串键值对象');
  }
  return raw.cast<String, String>();
}
