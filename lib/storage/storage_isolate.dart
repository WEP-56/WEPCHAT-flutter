import 'dart:async';
import 'dart:isolate';

import '../core/errors.dart';
import 'db_worker.dart';
import 'isolate_protocol.dart';

/// isolate 启动参数。[replyTo] 同时承载握手消息与后续所有响应
/// ——用一个端口而不是两个，就没有"响应端口还没到就收到请求"的窗口。
class _WorkerConfig {
  const _WorkerConfig(this.replyTo, this.dbPath, this.blobRoot);

  final SendPort replyTo;
  final String dbPath;
  final String blobRoot;
}

/// 数据库打开成功，[requestPort] 用于后续请求。
class _WorkerReady {
  const _WorkerReady(this.requestPort);

  final SendPort requestPort;
}

/// 数据库打开失败（迁移拒绝、库文件损坏、native 库加载不到）。
class _WorkerFailed {
  const _WorkerFailed(this.error, this.stackTrace);

  final Object error;
  final String stackTrace;
}

/// 长驻 DB isolate 的宿主端。
///
/// 所有读写经 [SendPort] 串行，同时满足两条约束：
/// - 不在 UI isolate 做阻塞 IO（AGENTS.md §5.3）
/// - 同一工作区的写必须串行（AGENTS.md §6.2）在存储层的对应要求
///
/// WAL 允许再开只读连接做并发读，第一版不做——先用单连接把正确性做对
/// （存储设计 §10）。
class StorageIsolate {
  StorageIsolate._(this._responses);

  final ReceivePort _responses;
  final Completer<SendPort> _ready = Completer<SendPort>();
  final Map<int, Completer<Object?>> _pending = <int, Completer<Object?>>{};

  late final Isolate _isolate;
  late final SendPort _requestPort;

  int _nextRequestId = 1;
  bool _closed = false;

  /// 启动 isolate 并等它打开数据库。
  ///
  /// [dbPath] 与 [blobRoot] 由调用方从 platform 层解析后传入——storage 层
  /// 不 import flutter，拿不到 path_provider（实施 TODO §1-1）。
  static Future<StorageIsolate> spawn({
    required String dbPath,
    required String blobRoot,
  }) async {
    final ReceivePort responses = ReceivePort();
    final StorageIsolate host = StorageIsolate._(responses);
    host._listen();

    try {
      host._isolate = await Isolate.spawn(
        _workerMain,
        _WorkerConfig(responses.sendPort, dbPath, blobRoot),
        debugName: 'wepchat-db',
        // isolate 意外退出时往同一端口发 null，[_listen] 据此让所有等待中的
        // 请求失败。不加这个，worker 崩掉后每个 Future 都永远挂着。
        onExit: responses.sendPort,
      );
      host._requestPort = await host._ready.future;
      return host;
    } on Object {
      responses.close();
      rethrow;
    }
  }

  void _listen() {
    _responses.listen((Object? message) {
      switch (message) {
        case _WorkerReady(:final SendPort requestPort):
          _ready.complete(requestPort);

        case _WorkerFailed(:final Object error, :final String stackTrace):
          // 保留原始领域错误（通常是迁移的 StorageError），不再包一层，
          // 否则"版本过高请升级"这种要给用户看的信息会被埋掉。
          _ready.completeError(error, StackTrace.fromString(stackTrace));

        case DbSuccess(:final int id, :final Object? value):
          _pending.remove(id)?.complete(value);

        case DbFailure(
          :final int id,
          :final Object error,
          :final String stackTrace,
        ):
          _pending
              .remove(id)
              ?.completeError(error, StackTrace.fromString(stackTrace));

        // onExit 的通知。正常关闭时 [close] 已经清空了 _pending，
        // 所以这里还有内容就说明 worker 是意外死的。
        case null:
          _failAllPending(const StorageError('DB isolate 意外退出，请求未完成'));
          if (!_ready.isCompleted) {
            _ready.completeError(const StorageError('DB isolate 在完成握手前退出'));
          }

        default:
          throw StorageError(
            'DB isolate 返回了意外消息',
            context: <String, Object?>{'type': message.runtimeType},
          );
      }
    });
  }

  /// 发一个请求并等结果。
  ///
  /// 返回值类型由请求类型决定，调用方（`WepStorage`）负责断言。
  Future<T> send<T>(DbRequest Function(int id) build) {
    if (_closed) {
      return Future<T>.error(const StorageError('存储已关闭，无法继续请求'));
    }
    return _send<T>(build);
  }

  /// 不带关闭检查的发送。[close] 自己要发 [ShutdownRequest]，不能被
  /// `_closed` 挡住——那会让 worker 永远不 dispose，数据库句柄留在
  /// 打开状态（Windows 上表现为库文件无法删除）。
  Future<T> _send<T>(DbRequest Function(int id) build) {
    final int id = _nextRequestId++;
    final Completer<Object?> completer = Completer<Object?>();
    _pending[id] = completer;
    _requestPort.send(build(id));
    return completer.future.then((Object? value) => value as T);
  }

  /// 关闭 isolate。
  ///
  /// 等 worker 确认 `dispose()` 之后才 kill：直接 kill 不会关掉 SQLite 的
  /// native 句柄，库文件会一直被进程占着。
  Future<void> close() async {
    if (_closed) return;
    _closed = true;

    try {
      await _send<Object?>(ShutdownRequest.new);
    } on Object {
      // worker 已经死了也算达到目标状态（连接不再持有）。
    }

    _failAllPending(const StorageError('存储关闭，请求被丢弃'));
    _responses.close();
    _isolate.kill(priority: Isolate.immediate);
  }

  void _failAllPending(Object error) {
    if (_pending.isEmpty) return;
    final List<Completer<Object?>> waiting = _pending.values.toList();
    _pending.clear();
    for (final Completer<Object?> c in waiting) {
      if (!c.isCompleted) c.completeError(error);
    }
  }
}

/// isolate 入口。
void _workerMain(_WorkerConfig config) {
  final DbWorker worker;
  try {
    worker = DbWorker.open(dbPath: config.dbPath, blobRoot: config.blobRoot);
  } on Object catch (e, st) {
    config.replyTo.send(_WorkerFailed(_sendable(e), st.toString()));
    return;
  }

  final ReceivePort requests = ReceivePort();
  config.replyTo.send(_WorkerReady(requests.sendPort));

  requests.listen((Object? message) {
    if (message is! DbRequest) {
      throw StorageError(
        'DB isolate 收到了意外消息',
        context: <String, Object?>{'type': message.runtimeType},
      );
    }

    if (message is ShutdownRequest) {
      worker.dispose();
      config.replyTo.send(DbSuccess(message.id, null));
      requests.close();
      return;
    }

    try {
      config.replyTo.send(DbSuccess(message.id, worker.handle(message)));
    } on Object catch (e, st) {
      // 失败编码进响应，不让异常逃出 listen 回调——那会杀掉整个 isolate，
      // 后续所有请求永远挂着（AGENTS.md §1.3）。
      config.replyTo.send(DbFailure(message.id, _sendable(e), st.toString()));
    }
  });
}

/// sqlite3 抛的异常（`SqliteException`）不保证可跨 isolate 发送。
/// 转成领域错误再回传，同时保留原始信息用于诊断。
Object _sendable(Object error) {
  if (error is WepError) return error;
  return StorageError(
    '数据库操作失败',
    context: <String, Object?>{
      'cause': error.toString(),
      'causeType': error.runtimeType.toString(),
    },
  );
}
