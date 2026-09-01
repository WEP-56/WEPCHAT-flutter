import 'dart:async';

/// 取消令牌。Dart 的 Future 不可取消，所有长耗时操作必须接受此令牌并在关键点检查。
///
/// 设计参考 C# 的 CancellationToken。调用方持有 source，操作接收 token。
class CancellationToken {
  CancellationToken._({required bool isCancelled})
    : _isCancelled = isCancelled,
      _completer = isCancelled ? (Completer<void>()..complete()) : null;

  /// 永不取消的令牌，可以作为占位传递。
  static final CancellationToken none = CancellationToken._(isCancelled: false);

  bool _isCancelled;
  final Completer<void>? _completer;
  final List<void Function()> _callbacks = <void Function()>[];

  bool get isCancelled => _isCancelled;

  /// 取消时立即完成的 Future，可用于 select 等待。
  Future<void> get whenCancelled {
    final Completer<void>? completed = _completer;
    if (completed != null) return completed.future;
    final Completer<void> c = Completer<void>();
    _callbacks.add(c.complete);
    return c.future;
  }

  /// 如果已取消，抛出 [CancelledException]。在长操作的关键点调用。
  void throwIfCancelled() {
    if (_isCancelled) throw CancelledException();
  }

  /// 注册取消回调。立即取消时回调会同步执行。
  void onCancel(void Function() callback) {
    if (_isCancelled) {
      callback();
    } else {
      _callbacks.add(callback);
    }
  }

  void _cancel() {
    if (_isCancelled) return;
    _isCancelled = true;
    for (final void Function() cb in _callbacks) {
      try {
        cb();
      } catch (_) {
        // 回调失败不阻止其他回调执行
      }
    }
    _callbacks.clear();
  }
}

/// 取消令牌的源，可派生子 token。
class CancellationTokenSource {
  CancellationTokenSource() : _token = CancellationToken._(isCancelled: false);

  final CancellationToken _token;

  CancellationToken get token => _token;

  bool get isCancelled => _token.isCancelled;

  /// 取消此 source 及其派生的所有 token。
  void cancel() {
    _token._cancel();
  }

  /// 从此 source 派生子 token。父取消时，子自动取消。
  CancellationToken derive() {
    final CancellationToken child = CancellationToken._(
      isCancelled: _token.isCancelled,
    );
    if (!_token.isCancelled) {
      _token.onCancel(child._cancel);
    }
    return child;
  }
}

/// 操作被取消时抛出。这是正常控制流，不应记录为错误。
class CancelledException implements Exception {
  const CancelledException();

  @override
  String toString() => 'Operation was cancelled';
}
