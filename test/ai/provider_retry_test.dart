import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/ai/stream_event.dart';
import 'package:wepchat/core/cancellation_token.dart';

const _request = ProviderRequest(
  model: ModelSpec(
    id: 'test',
    providerId: 'test',
    displayName: 'Test',
    contextWindow: 8192,
    maxOutputTokens: 1024,
  ),
  messages: <ChatMessageModel>[],
);
const _partial = ChatMessageModel(
  role: MessageRole.assistant,
  parts: <ContentPart>[TextPart('已收到')],
);
const _retry = ProviderRetryPolicy(
  maxAttempts: 3,
  initialBackoff: Duration.zero,
);
const _deadline = Duration(seconds: 1);

class _Api extends ProviderApi {
  _Api(this.attempt);
  final Stream<StreamEvent> Function(int) attempt;
  int calls = 0;

  @override
  Stream<StreamEvent> stream(
    ProviderRequest request,
    CancellationToken token,
  ) => attempt(++calls);
}

StreamDone _done(StopReason reason) =>
    StreamDone(message: _partial.copyWith(stopReason: reason));

void main() {
  // 上游保持打开：只有包装层真正即时转发，moveNext 才会在截止前完成。
  // 仅在 toList() 后断言顺序无法发现“缓存整轮再重放”的回归。
  for (final StreamEvent delta in <StreamEvent>[
    const StreamTextDelta(message: _partial, delta: '已收到'),
    const StreamThinkingDelta(message: _partial, delta: '思考'),
    const StreamToolCallDelta(
      message: _partial,
      callId: 'call-1',
      toolName: 'read_file',
      argumentsDelta: '{"path":',
    ),
  ]) {
    for (final int attempts in <int>[1, 3]) {
      test('${delta.runtimeType} 在流结束前转发（最多 $attempts 次尝试）', () async {
        final source = StreamController<StreamEvent>();
        final api = _Api((_) => source.stream);
        final output = StreamIterator(
          api.streamWithRetry(
            _request,
            CancellationToken.none,
            policy: ProviderRetryPolicy(maxAttempts: attempts),
          ),
        );
        try {
          final next = output.moveNext();
          source.add(delta);
          expect(await next.timeout(_deadline), isTrue);
          expect(output.current, same(delta));
          expect(source.isClosed, isFalse);
          source.add(_done(StopReason.stop));
          expect(await output.moveNext().timeout(_deadline), isTrue);
          expect(output.current, isA<StreamDone>());
          expect(await output.moveNext().timeout(_deadline), isFalse);
          expect(api.calls, 1);
        } finally {
          unawaited(source.close());
          await output.cancel();
        }
      });
    }

    test('${delta.runtimeType} 后失败不重试、不重复输出', () async {
      final api = _Api(
        (_) =>
            Stream.fromIterable(<StreamEvent>[delta, _done(StopReason.error)]),
      );
      final events = await api
          .streamWithRetry(_request, CancellationToken.none, policy: _retry)
          .toList();
      expect(api.calls, 1);
      expect(events, hasLength(2));
      expect(events.first, same(delta));
      expect((events.last as StreamDone).stopReason, StopReason.error);
    });
  }

  test('无增量的失败可重试，开始和结束只通知一次', () async {
    final api = _Api(
      (int attempt) => Stream.fromIterable(<StreamEvent>[
        const StreamStart(message: _partial),
        if (attempt == 1)
          _done(StopReason.error)
        else ...<StreamEvent>[
          const StreamTextDelta(message: _partial, delta: '已收到'),
          _done(StopReason.stop),
        ],
      ]),
    );
    final events = await api
        .streamWithRetry(_request, CancellationToken.none, policy: _retry)
        .toList();
    expect(api.calls, 2);
    expect(events.whereType<StreamStart>(), hasLength(1));
    expect(events.whereType<StreamTextDelta>(), hasLength(1));
    expect(events.whereType<StreamDone>(), hasLength(1));
    expect((events.last as StreamDone).stopReason, StopReason.stop);
  });

  test('重试用尽保留最终失败', () async {
    final api = _Api((_) => Stream.value(_done(StopReason.error)));
    final events = await api
        .streamWithRetry(_request, CancellationToken.none, policy: _retry)
        .toList();
    expect(api.calls, 3);
    expect((events.single as StreamDone).stopReason, StopReason.error);
  });

  test('增量之后异常仍产生结束事件并保留已显示内容', () async {
    final api = _Api((_) async* {
      yield const StreamTextDelta(message: _partial, delta: '已收到');
      throw StateError('connection lost');
    });
    final events = await api
        .streamWithRetry(_request, CancellationToken.none, policy: _retry)
        .toList();
    expect(api.calls, 1);
    expect((events.last as StreamDone).stopReason, StopReason.error);
    expect(events.last.message.text, '已收到');
  });

  test('退避时取消立即结束，不再尝试请求', () async {
    final source = CancellationTokenSource();
    final failed = Completer<void>();
    final api = _Api((_) async* {
      yield _done(StopReason.error);
      // 包装层退出本次流后进入退避；onCancel 也必须触发此清理。
    });
    final subscription = api
        .streamWithRetry(
          _request,
          source.token,
          policy: const ProviderRetryPolicy(
            maxAttempts: 3,
            initialBackoff: Duration(seconds: 4),
          ),
        )
        .toList();
    // 下一次事件循环执行时，第一个异步流已产生失败并进入退避。
    Timer.run(failed.complete);
    await failed.future;
    source.cancel();
    final events = await subscription.timeout(_deadline);
    expect(api.calls, 1);
    expect((events.single as StreamDone).stopReason, StopReason.aborted);
  });

  test('请求前已取消也产生 aborted 结束事件', () async {
    final source = CancellationTokenSource()..cancel();
    final api = _Api((_) => Stream.value(_done(StopReason.stop)));
    final events = await api.streamWithRetry(_request, source.token).toList();
    expect(api.calls, 0);
    expect((events.single as StreamDone).stopReason, StopReason.aborted);
  });
}
