import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/platform/workspace_guard.dart';
import 'package:wepchat/runtime/wep_js_runtime.dart';
import 'package:wepchat/tools/script/run_js_tool.dart';
import 'package:wepchat/tools/tool.dart';

void main() {
  late Directory workspace;
  late ToolContext context;

  setUp(() {
    workspace = Directory.systemTemp.createTempSync('wep_run_js_');
    context = ToolContext(
      sessionId: 'session-js',
      workspace: WorkspaceGuard(workspace.path),
      token: CancellationToken.none,
    );
  });

  tearDown(() {
    workspace.deleteSync(recursive: true);
  });

  test('校验 code 与 timeout_ms', () async {
    const RunJsTool tool = RunJsTool(runtime: _ResultRuntime());

    expect(
      (await tool.execute(const <String, Object?>{}, context)).isError,
      isTrue,
    );
    expect(
      (await tool.execute(const <String, Object?>{
        'code': '1',
        'timeout_ms': 100,
      }, context)).isError,
      isTrue,
    );
  });

  test('组合 console 输出和完成值', () async {
    const RunJsTool tool = RunJsTool(runtime: _ResultRuntime());
    final ToolResult result = await tool.execute(const <String, Object?>{
      'code': '40 + 2',
    }, context);

    expect(result.outcome, ToolOutcome.ok);
    expect(result.content, 'log line\n42');
  });

  test('wep.fs 只能在工作区内读写并报告产物', () async {
    const RunJsTool tool = RunJsTool(runtime: _BridgeRuntime());
    final ToolResult result = await tool.execute(const <String, Object?>{
      'code': 'bridge test',
    }, context);

    expect(result.outcome, ToolOutcome.ok);
    expect(
      File(
        '${workspace.path}${Platform.pathSeparator}report.html',
      ).readAsStringSync(),
      'hello',
    );
    expect(result.uiPayload?['paths'], equals(<String>['report.html']));
  });

  test('超时和取消保留不同结果状态', () async {
    final ToolResult timedOut = await const RunJsTool(
      runtime: _ThrowingRuntime(timeout: true),
    ).execute(const <String, Object?>{'code': 'while (true) {}'}, context);
    expect(timedOut.outcome, ToolOutcome.failed);
    expect(timedOut.content, contains('已中断'));

    final ToolResult cancelled = await const RunJsTool(
      runtime: _ThrowingRuntime(timeout: false),
    ).execute(const <String, Object?>{'code': 'work()'}, context);
    expect(cancelled.outcome, ToolOutcome.cancelled);
  });
}

class _ResultRuntime implements WepJsRuntime {
  const _ResultRuntime();

  @override
  Future<JsExecutionResult> run({
    required String code,
    required JsBridgeHandler bridge,
    required CancellationToken token,
    Duration timeout = kJsExecutionTimeout,
  }) async => const JsExecutionResult(value: 42, logs: <String>['log line']);
}

class _BridgeRuntime implements WepJsRuntime {
  const _BridgeRuntime();

  @override
  Future<JsExecutionResult> run({
    required String code,
    required JsBridgeHandler bridge,
    required CancellationToken token,
    Duration timeout = kJsExecutionTimeout,
  }) async {
    await bridge(<String, Object?>{
      'action': 'writeText',
      'path': 'report.html',
      'content': 'hello',
    });
    final Object? value = await bridge(<String, Object?>{
      'action': 'readText',
      'path': 'report.html',
    });
    await expectLater(
      bridge(<String, Object?>{'action': 'readText', 'path': '../outside.txt'}),
      throwsArgumentError,
    );
    return JsExecutionResult(value: value, logs: const <String>[]);
  }
}

class _ThrowingRuntime implements WepJsRuntime {
  const _ThrowingRuntime({required this.timeout});

  final bool timeout;

  @override
  Future<JsExecutionResult> run({
    required String code,
    required JsBridgeHandler bridge,
    required CancellationToken token,
    Duration timeout = kJsExecutionTimeout,
  }) async {
    if (this.timeout) throw const JsExecutionTimedOut();
    throw const CancelledException();
  }
}
