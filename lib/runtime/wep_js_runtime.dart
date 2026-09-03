/// Application-owned JavaScript runtime boundary.
///
/// FJS is deliberately kept behind this small interface so tools do not depend
/// on a plugin API or receive real device paths.
library;

import 'dart:async';
import 'dart:convert';

import 'package:fjs/fjs.dart';

import '../core/cancellation_token.dart';

const Duration kJsExecutionTimeout = Duration(seconds: 12);
const int kJsOutputLimit = 64 * 1024;
const int kJsMemoryLimit = 64 * 1024 * 1024;

typedef JsBridgeHandler =
    Future<Object?> Function(Map<String, Object?> request);

class JsExecutionResult {
  const JsExecutionResult({required this.value, required this.logs});

  final Object? value;
  final List<String> logs;
}

class JsExecutionTimedOut implements Exception {
  const JsExecutionTimedOut();
}

/// One isolated FJS engine per tool call. Closing the engine is the native
/// cancellation mechanism for both a dead loop and pending async work.
abstract interface class WepJsRuntime {
  Future<JsExecutionResult> run({
    required String code,
    required JsBridgeHandler bridge,
    required CancellationToken token,
    Duration timeout = kJsExecutionTimeout,
  });
}

class FjsWepJsRuntime implements WepJsRuntime {
  const FjsWepJsRuntime();

  // FRB's generated initializer is process-wide and rejects a second call.
  // Keep the in-flight future so concurrent tool calls share one init.
  static Future<void>? _initFuture;

  static Future<void> _ensureFjsInitialized() {
    return _initFuture ??= LibFjs.init();
  }

  @override
  Future<JsExecutionResult> run({
    required String code,
    required JsBridgeHandler bridge,
    required CancellationToken token,
    Duration timeout = kJsExecutionTimeout,
  }) async {
    await _ensureFjsInitialized();
    final JsEngine engine = await JsEngine.create(
      builtins: JsBuiltinOptions.web(),
      runtimeOptions: JsEngineRuntimeOptions(
        memoryLimit: BigInt.from(kJsMemoryLimit),
        maxStackSize: BigInt.from(512 * 1024),
        info: 'wepchat-run-js',
      ),
    );

    bool timedOut = false;
    Future<void>? closeFuture;
    void closeEngine() {
      closeFuture ??= engine.close();
    }

    token.onCancel(closeEngine);
    final Timer timer = Timer(timeout, () {
      timedOut = true;
      closeEngine();
    });

    try {
      await engine.init(
        bridge: (JsValue value) async {
          final Object? raw = value.value;
          if (raw is! Map) {
            return JsResult.ok(
              JsValue.from(<String, Object?>{
                'ok': false,
                'error': 'wep bridge 参数必须是对象',
              }),
            );
          }
          final Map<String, Object?> request = <String, Object?>{
            for (final MapEntry<Object?, Object?> item in raw.entries)
              if (item.key is String) item.key as String: item.value,
          };
          try {
            final Object? result = await bridge(request);
            return JsResult.ok(
              JsValue.from(<String, Object?>{'ok': true, 'value': result}),
            );
          } on Object catch (e) {
            return JsResult.ok(
              JsValue.from(<String, Object?>{
                'ok': false,
                'error': e.toString(),
              }),
            );
          }
        },
      );

      await engine.eval(source: JsCode.code(_prelude));
      final JsValue value = await engine.eval(source: JsCode.code(code));
      final JsValue logValue = await engine.eval(
        source: const JsCode.code('__wepLogs'),
      );
      return JsExecutionResult(
        value: value.value,
        logs: _readLogs(logValue.value),
      );
    } catch (e) {
      if (timedOut) throw const JsExecutionTimedOut();
      if (token.isCancelled) throw const CancelledException();
      rethrow;
    } finally {
      timer.cancel();
      closeEngine();
      try {
        await closeFuture;
      } on Object catch (error) {
        // Cancellation/timeout already has a domain outcome. For ordinary
        // executions, a failed shutdown is a real runtime failure and must not
        // be silently discarded.
        if (!timedOut && !token.isCancelled) {
          throw StateError('JavaScript runtime shutdown failed: $error');
        }
      }
    }
  }

  static const String _prelude =
      '''
// Console output is retained separately so the script's completion value is
// preserved (for example, `40 + 2` still evaluates to 42).
    // `fetch` remains available through FJS's web builtin by explicit product
    // choice; filesystem access is only exposed through the wep bridge below.
const __wepLogs = [];
let __wepLogChars = 0;
const __wepPush = (...values) => {
  if (__wepLogChars >= $kJsOutputLimit) return;
  const rendered = values.map((value) => {
    try { return typeof value === "string" ? value : JSON.stringify(value); }
    catch (_) { return String(value); }
  }).join(" ");
  const bounded = rendered.slice(0, $kJsOutputLimit - __wepLogChars);
  __wepLogs.push(bounded);
  __wepLogChars += bounded.length + 1;
};
globalThis.console = { log: __wepPush, info: __wepPush, warn: __wepPush, error: __wepPush };
globalThis.wep = { fs: {
  listFiles: async (path = "", recursive = true) => {
    const response = await fjs.bridge_call({ action: "listFiles", path, recursive });
    if (!response.ok) throw new Error(response.error);
    return response.value;
  },
  readText: async (path) => {
    const response = await fjs.bridge_call({ action: "readText", path });
    if (!response.ok) throw new Error(response.error);
    return response.value;
  },
  writeText: async (path, content) => {
    const response = await fjs.bridge_call({ action: "writeText", path, content });
    if (!response.ok) throw new Error(response.error);
    return response.value;
  }
} };
''';

  static List<String> _readLogs(Object? raw) {
    if (raw is! List) return const <String>[];
    final String joined = raw.whereType<String>().join('\n');
    final String bounded = joined.length <= kJsOutputLimit
        ? joined
        : '${joined.substring(0, kJsOutputLimit)}…';
    return bounded.isEmpty ? const <String>[] : bounded.split('\n');
  }
}

String formatJsValue(Object? value) {
  if (value == null) return 'null';
  if (value is String) return value;
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } on Object {
    return value.toString();
  }
}
