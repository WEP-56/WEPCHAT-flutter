import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/cancellation_token.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_connection.dart';
import '../mcp/mcp_oauth_login.dart';
import '../mcp/mcp_session.dart';
import '../platform/mcp_transports.dart';
import 'app_settings.dart';

sealed class McpProbeState {
  const McpProbeState();
}

final class McpChecking extends McpProbeState {
  const McpChecking();
}

final class McpDiscovered extends McpProbeState {
  McpDiscovered(Iterable<String> tools)
    : tools = List<String>.unmodifiable(tools);
  final List<String> tools;
}

final class McpProbeFailed extends McpProbeState {
  const McpProbeFailed(this.message);
  final String message;
}

/// Flutter owns configuration notifications; each runtime session stays pure Dart.
class McpController extends ChangeNotifier {
  McpController({
    required AppSettings settings,
    McpConnectionFactory? factory,
    bool? supportsStdio,
  }) : _settings = settings,
       _configuration = settings.mcp,
       _factory = factory ?? createMcpConnection,
       supportsStdio = supportsStdio ?? supportsLocalMcp {
    _settings.addListener(_settingsChanged);
  }

  final AppSettings _settings;
  McpSettings _configuration;
  final McpConnectionFactory _factory;
  final bool supportsStdio;
  final Set<McpSession> _sessions = <McpSession>{};
  final Map<String, McpProbeState> _probes = <String, McpProbeState>{};
  final Map<String, CancellationTokenSource> _authorizing =
      <String, CancellationTokenSource>{};
  final Map<String, String> _authErrors = <String, String>{};
  Future<void>? _closing;
  String? _cleanupError;
  bool _disposed = false;
  bool _stopped = false;

  McpProbeState? probe(String id) => _probes[id];
  String? get cleanupError => _cleanupError;

  /// 该服务器是否持有可用的 OAuth 令牌。非 OAuth 服务器恒为 false。
  bool isAuthorized(String id) => _settings.mcpAuth.tokenSet(id) != null;

  bool isAuthorizing(String id) => _authorizing.containsKey(id);

  String? authError(String id) => _authErrors[id];

  /// 走一次 OAuth 授权码流程，成功后立刻用一次真实连接确认令牌可用。
  ///
  /// 返回值只表示"这次操作是否成功"，登录状态以 [isAuthorized] 为准——授权
  /// 可能已经完成而随后的连接验证失败。失败原因通过 [authError] 读取。
  Future<bool> authorize(
    String id, {
    required Future<bool> Function(McpAuthorizationRequest request) confirm,
    required Future<void> Function(Uri authorizationUri) openBrowser,
    Duration timeout = kMcpAuthorizationTimeout,
  }) async {
    if (!_configuration.enabled) {
      throw const McpFailure('请先启用 MCP 并确认工作区边界说明');
    }
    final McpServerConfig? server = _configuration.server(id);
    if (server == null) throw const McpFailure('MCP server 已被删除');
    final McpEndpoint endpoint = server.endpoint;
    if (endpoint is! McpRemoteEndpoint || endpoint.oauthClient == null) {
      throw const McpFailure('该服务器没有启用 OAuth 登录');
    }
    if (_authorizing.containsKey(id)) {
      throw const McpFailure('该服务器正在授权中');
    }
    final CancellationTokenSource source = CancellationTokenSource();
    _authorizing[id] = source;
    _authErrors.remove(id);
    _notify();
    try {
      await runMcpOAuthLogin(
        server: server,
        endpoint: endpoint,
        store: _settings.mcpAuth,
        token: source.token,
        confirm: confirm,
        openBrowser: openBrowser,
        timeout: timeout,
      );
      final McpSession session = await _open(
        <McpServerConfig>[server],
        source.token,
        null,
      );
      await session.close();
      return true;
    } on CancelledException {
      _authErrors[id] = '授权已取消';
      return false;
    } on McpFailure catch (error) {
      _authErrors[id] = error.message;
      return false;
    } finally {
      _authorizing.remove(id);
      source.cancel();
      _notify();
    }
  }

  /// 清除该服务器的令牌并撤销现有连接。
  ///
  /// 凭据变了和配置变更一样，不能继续用已经失效的授权跑完当前轮次。
  Future<void> signOut(String id) async {
    await _settings.mcpAuth.saveTokenSet(id, null);
    _authErrors.remove(id);
    _cancelSessions();
    _notify();
  }

  Future<McpSession> openSession(
    CancellationToken token, {
    String? workspaceRoot,
  }) => _open(McpSession.enabledServers(_configuration), token, workspaceRoot);

  Future<McpSession> _open(
    Iterable<McpServerConfig> servers,
    CancellationToken token,
    String? workspaceRoot,
  ) async {
    if (_stopped) throw const CancelledException();
    late final McpSession session;
    session = McpSession(
      servers: servers,
      factory: _factory,
      parentToken: token,
      supportsStdio: supportsStdio,
      authStore: _settings.mcpAuth,
      workspaceRoot: workspaceRoot,
      onDiscovered: (McpServerConfig server, List<McpToolInfo> tools) {
        _probes[server.id] = McpDiscovered(
          tools.map((McpToolInfo t) => t.name),
        );
        _notify();
      },
      onClosed: () => _sessions.remove(session),
    );
    _sessions.add(session);
    try {
      await session.initialize();
      return session;
    } on Object {
      await session.close();
      rethrow;
    }
  }

  Future<void> testServer(
    String id,
    CancellationToken token, {
    String? workspaceRoot,
  }) async {
    if (!_configuration.enabled) {
      throw const McpFailure('请先启用 MCP 并确认工作区边界说明');
    }
    final McpServerConfig? server = _configuration.server(id);
    if (server == null) throw const McpFailure('MCP server 已被删除');
    if (_probes[id] is McpChecking) return;
    final McpSettings snapshot = _configuration;
    _probes[id] = const McpChecking();
    _notify();
    try {
      final McpSession session = await _open(
        <McpServerConfig>[server],
        token,
        workspaceRoot,
      );
      await session.close();
    } on CancelledException {
      if (identical(snapshot, _configuration)) {
        _probes[id] = const McpProbeFailed('连接测试已取消');
      }
    } on McpFailure catch (error) {
      if (identical(snapshot, _configuration)) {
        _probes[id] = McpProbeFailed(error.message);
      }
    } finally {
      _notify();
    }
  }

  void _settingsChanged() {
    if (identical(_configuration, _settings.mcp)) return;
    _configuration = _settings.mcp;
    _probes.clear();
    _cleanupError = null;
    // Reconfiguration revokes existing connections immediately. The current
    // turn keeps its old declarations, whose cancelled bindings cannot execute.
    _cancelSessions();
    _notify();
  }

  /// 撤销当前所有连接。取消是正常控制流，会话自身的清理仍然是异步的。
  void _cancelSessions() {
    for (final McpSession session in _sessions.toList()) {
      session.cancel();
      unawaited(_closeSession(session));
    }
  }

  Future<void> _closeSession(McpSession session) async {
    try {
      await session.close();
    } on McpFailure catch (error) {
      _cleanupError = error.message;
      _notify();
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _stopped = true;
    _settings.removeListener(_settingsChanged);
    final List<McpSession> sessions = _sessions.toList();
    for (final McpSession session in sessions) {
      session.cancel();
    }
    for (final McpSession session in sessions) {
      await _closeSession(session);
    }
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(close());
    super.dispose();
  }
}
