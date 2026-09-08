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

final class McpRemoteEndpoint extends McpEndpoint {
  McpRemoteEndpoint({
    required this.kind,
    required this.url,
    Map<String, String> headers = const <String, String>{},
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
  }

  @override
  final McpTransportKind kind;
  final Uri url;
  final Map<String, String> headers;

  @override
  Map<String, Object?> toJson() => <String, Object?>{
    'transport': kind.name,
    'url': url.toString(),
    'headers': headers,
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
