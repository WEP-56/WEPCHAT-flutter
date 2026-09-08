import 'dart:async';
import 'dart:io';

import 'package:mcp_dart/mcp_dart.dart' as sdk;
import 'package:path/path.dart' as p;

import '../mcp/mcp_config.dart';
import '../mcp/mcp_connection.dart';

const Duration _shutdownTimeout = Duration(seconds: 5);
const Set<String> _inheritedEnvironment = <String>{
  'APPDATA',
  'LOCALAPPDATA',
  'PATH',
  'PATHEXT',
  'SYSTEMROOT',
  'SYSTEMDRIVE',
  'TEMP',
  'TMP',
  'USERPROFILE',
  'HOMEDRIVE',
  'HOMEPATH',
  'COMSPEC',
  'PROGRAMFILES',
  'PROGRAMFILES(X86)',
  'PROGRAMDATA',
};

/// Owns the process handle as well as the protocol pipes, so npx/uvx children
/// can be terminated as a tree. This is deliberately not a workspace sandbox.
final class WindowsMcpStdioTransport extends sdk.Transport {
  WindowsMcpStdioTransport(this.endpoint, {this.workspaceRoot});

  final McpStdioEndpoint endpoint;
  final String? workspaceRoot;
  Process? _process;
  sdk.IOStreamTransport? _pipes;
  StreamSubscription<List<int>>? _stderr;
  Future<void>? _starting;
  Future<void>? _closing;
  bool _closed = false;
  bool _exited = false;
  bool _notifiedClose = false;

  @override
  String? get sessionId => null;

  @override
  Future<void> start() {
    if (!Platform.isWindows) {
      throw const McpFailure('stdio MCP 仅支持 Windows');
    }
    if (_starting != null || _closed) throw StateError('MCP 进程不能重复启动');
    return _starting = _start();
  }

  Future<void> _start() async {
    final Map<String, String> environment = mcpProcessEnvironment(
      Platform.environment,
      endpoint.environment,
    );
    final String? cwd = endpoint.workingDirectory ?? workspaceRoot;
    final McpLaunchCommand launch = await resolveMcpLaunch(
      endpoint.command,
      endpoint.arguments,
      environment,
      cwd,
    );
    if (_closed) throw const McpFailure('MCP 启动已取消');
    final Process process;
    try {
      process = await Process.start(
        launch.executable,
        launch.arguments,
        workingDirectory: cwd,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException {
      throw const McpFailure('无法启动 MCP 进程，请检查可执行文件、工作目录和运行环境');
    }
    _process = process;
    unawaited(process.exitCode.then<void>((_) => _exited = true));
    // stderr is a separate diagnostic channel and may contain credentials.
    // Drain it without copying it into the protocol, chat history or logs.
    _stderr = process.stderr.listen(
      (_) {},
      onError: (Object error, StackTrace stack) => _reportPipeFailure(),
    );
    unawaited(
      process.stdin.done.then<void>(
        (_) {},
        onError: (Object error, StackTrace stack) {
          if (!_closed) _reportPipeFailure();
        },
      ),
    );
    if (_closed) throw const McpFailure('MCP 启动已取消');
    final sdk.IOStreamTransport pipes = sdk.IOStreamTransport(
      stream: process.stdout,
      sink: process.stdin,
      maxIncomingMessageBytes: kMcpMaxMessageBytes,
    );
    _pipes = pipes;
    pipes.onmessage = (sdk.JsonRpcMessage message) => onmessage?.call(message);
    pipes.onerror = (Error error) => onerror?.call(error);
    pipes.onclose = () {
      if (!_closed) _reportPipeFailure();
    };
    await pipes.start();
  }

  void _reportPipeFailure() {
    if (_closed) return;
    onerror?.call(StateError('MCP 进程退出或通信管道断开'));
    unawaited(
      close().catchError((Object error) {
        onerror?.call(StateError('MCP 进程清理失败'));
      }),
    );
  }

  @override
  Future<void> send(sdk.JsonRpcMessage message, {int? relatedRequestId}) async {
    final sdk.IOStreamTransport? pipes = _pipes;
    if (_closed || pipes == null) throw StateError('MCP 进程尚未连接或已经关闭');
    await pipes.send(message, relatedRequestId: relatedRequestId);
  }

  @override
  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    _closed = true;
    try {
      try {
        await _starting;
      } on Object {
        // start() reports the failure to connect(); cleanup must still reap a
        // process that arrived while cancellation was in flight.
        if (_process == null) return;
      }
      await _pipes?.close();
      final Process? process = _process;
      if (process != null) {
        await _terminateTree(process);
        try {
          await process.stdin.close();
        } on FileSystemException {
          if (!_exited) throw const McpFailure('关闭 MCP 输入管道失败');
        }
      }
    } finally {
      await _stderr?.cancel();
      if (!_notifiedClose) {
        _notifiedClose = true;
        onclose?.call();
      }
    }
  }

  Future<void> _terminateTree(Process process) async {
    if (_exited) return;
    final String? systemRoot = _environmentValue(
      Platform.environment,
      'SYSTEMROOT',
    );
    if (systemRoot == null) {
      throw const McpFailure('无法定位 Windows 进程清理工具');
    }
    final ProcessResult result;
    try {
      result = await Process.run(
        p.join(systemRoot, 'System32', 'taskkill.exe'),
        <String>['/PID', '${process.pid}', '/T', '/F'],
        runInShell: false,
      ).timeout(_shutdownTimeout);
      if (result.exitCode != 0 && !_exited) {
        throw McpFailure('结束 MCP 进程树失败（退出码 ${result.exitCode}）');
      }
      await process.exitCode.timeout(_shutdownTimeout);
      _exited = true;
    } on ProcessException {
      throw const McpFailure('无法执行 Windows MCP 进程清理');
    } on TimeoutException {
      throw const McpFailure('等待 MCP 进程退出超时');
    }
  }
}

Map<String, String> mcpProcessEnvironment(
  Map<String, String> parent,
  Map<String, String> configured,
) {
  final Map<String, String> result = <String, String>{
    for (final MapEntry<String, String> entry in parent.entries)
      if (_inheritedEnvironment.contains(entry.key.toUpperCase()))
        entry.key: entry.value,
  };
  for (final MapEntry<String, String> entry in configured.entries) {
    result.removeWhere(
      (String key, _) => key.toUpperCase() == entry.key.toUpperCase(),
    );
    result[entry.key] = entry.value;
  }
  return result;
}

final class McpLaunchCommand {
  const McpLaunchCommand(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

/// npx/npm .cmd wrappers are resolved to Node's CLI without shell interpolation.
/// Other batch files require an explicitly configured interpreter command.
Future<McpLaunchCommand> resolveMcpLaunch(
  String command,
  List<String> arguments,
  Map<String, String> environment,
  String? workingDirectory,
) async {
  final String executable = await _findExecutable(
    command,
    environment,
    workingDirectory,
  );
  final String extension = p.extension(executable).toLowerCase();
  if (extension != '.cmd' && extension != '.bat') {
    return McpLaunchCommand(executable, arguments);
  }
  final String name = p.basenameWithoutExtension(executable).toLowerCase();
  if (name != 'npx' && name != 'npm') {
    throw const McpFailure('批处理服务器请显式配置解释器；推荐使用 node、uvx 或 npx');
  }
  final String cli = p.join(
    p.dirname(executable),
    'node_modules',
    'npm',
    'bin',
    '$name-cli.js',
  );
  if (!await File(cli).exists()) {
    throw const McpFailure('未找到 npm CLI；请检查 Node.js 安装，或直接配置 node 和 CLI 路径');
  }
  final String siblingNode = p.join(p.dirname(executable), 'node.exe');
  final String node = await File(siblingNode).exists()
      ? siblingNode
      : await _findExecutable('node', environment, workingDirectory);
  return McpLaunchCommand(node, <String>[cli, ...arguments]);
}

Future<String> _findExecutable(
  String command,
  Map<String, String> environment,
  String? workingDirectory,
) async {
  final bool hasDirectory = command.contains('/') || command.contains(r'\');
  final List<String> directories = hasDirectory || p.isAbsolute(command)
      ? <String>[workingDirectory ?? Directory.current.path]
      : (_environmentValue(environment, 'PATH') ?? '').split(';');
  final List<String> suffixes = p.extension(command).isNotEmpty
      ? const <String>['']
      : const <String>['.exe', '.com', '.cmd', '.bat'];
  for (final String raw in directories) {
    final String directory = raw.trim().replaceAll(RegExp(r'^"|"$'), '');
    if (directory.isEmpty) continue;
    for (final String suffix in suffixes) {
      final String candidate = p.normalize(
        p.join(directory, '$command$suffix'),
      );
      if (await File(candidate).exists()) return candidate;
    }
  }
  throw const McpFailure('找不到 MCP 可执行文件，请安装 Node.js/uv 或填写可执行文件的绝对路径');
}

String? _environmentValue(Map<String, String> values, String key) {
  for (final MapEntry<String, String> entry in values.entries) {
    if (entry.key.toUpperCase() == key) return entry.value;
  }
  return null;
}
