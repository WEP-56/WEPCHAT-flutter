import 'dart:async';

import 'package:flutter/foundation.dart';

import '../core/cancellation_token.dart';
import '../mcp/mcp_config.dart';
import '../mcp/mcp_connection.dart';
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
    McpConnectionFactory factory = createMcpConnection,
    bool? supportsStdio,
  }) : _settings = settings,
       _configuration = settings.mcp,
       _factory = factory,
       supportsStdio = supportsStdio ?? supportsLocalMcp {
    _settings.addListener(_settingsChanged);
  }

  final AppSettings _settings;
  McpSettings _configuration;
  final McpConnectionFactory _factory;
  final bool supportsStdio;
  final Set<McpSession> _sessions = <McpSession>{};
  final Map<String, McpProbeState> _probes = <String, McpProbeState>{};
  Future<void>? _closing;
  String? _cleanupError;
  bool _disposed = false;
  bool _stopped = false;

  McpProbeState? probe(String id) => _probes[id];
  String? get cleanupError => _cleanupError;

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
    for (final McpSession session in _sessions.toList()) {
      session.cancel();
      unawaited(_closeSession(session));
    }
    _notify();
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
