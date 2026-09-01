import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/core/cancellation_token.dart';

void main() {
  group('CancellationToken', () {
    test('none token 永不取消', () {
      expect(CancellationToken.none.isCancelled, isFalse);
      CancellationToken.none.throwIfCancelled(); // 不抛异常
    });

    test('source.cancel() 取消 token', () {
      final CancellationTokenSource source = CancellationTokenSource();
      expect(source.isCancelled, isFalse);

      source.cancel();
      expect(source.isCancelled, isTrue);
      expect(source.token.isCancelled, isTrue);
      expect(
        () => source.token.throwIfCancelled(),
        throwsA(isA<CancelledException>()),
      );
    });

    test('onCancel 回调在取消时执行', () {
      final CancellationTokenSource source = CancellationTokenSource();
      bool called = false;
      source.token.onCancel(() => called = true);

      expect(called, isFalse);
      source.cancel();
      expect(called, isTrue);
    });

    test('onCancel 在已取消的 token 上立即执行', () {
      final CancellationTokenSource source = CancellationTokenSource();
      source.cancel();

      bool called = false;
      source.token.onCancel(() => called = true);
      expect(called, isTrue);
    });

    test('whenCancelled future 在取消时完成', () async {
      final CancellationTokenSource source = CancellationTokenSource();
      final Future<void> future = source.token.whenCancelled;

      bool completed = false;
      unawaited(future.then((_) => completed = true));

      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(completed, isFalse);

      source.cancel();
      await Future<void>.delayed(Duration.zero);
      expect(completed, isTrue);
    });

    test('derive() 派生子 token，父取消时子自动取消', () {
      final CancellationTokenSource parent = CancellationTokenSource();
      final CancellationToken child = parent.derive();

      expect(child.isCancelled, isFalse);
      parent.cancel();
      expect(child.isCancelled, isTrue);
    });

    test('派生自已取消的 source 得到已取消的 token', () {
      final CancellationTokenSource source = CancellationTokenSource();
      source.cancel();

      final CancellationToken child = source.derive();
      expect(child.isCancelled, isTrue);
    });

    test('多个回调都会执行，且单个失败不影响其他', () {
      final CancellationTokenSource source = CancellationTokenSource();
      int count = 0;

      source.token.onCancel(() => count++);
      source.token.onCancel(() => throw Exception('test'));
      source.token.onCancel(() => count++);

      source.cancel();
      expect(count, equals(2));
    });
  });
}
