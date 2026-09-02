import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/anthropic/anthropic_api.dart';
import 'package:wepchat/ai/http_transport.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/model_compat.dart';
import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/ai/stream_event.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/core/errors.dart';

const ModelSpec _model = ModelSpec(
  id: 'claude-sonnet-4-5',
  displayName: 'Claude Sonnet 4.5',
  providerId: 'anthropic',
  contextWindow: 200000,
  maxOutputTokens: 64000,
  compat: ModelCompat(
    thinking: ThinkingFormat.anthropicThinking,
    cache: CacheControlFormat.anthropic,
  ),
);

/// 用录好的 SSE 文本建一个适配器。
AnthropicApi apiWith(String sse, {int chunkSize = 16}) {
  return AnthropicApi(
    apiKey: 'test-key',
    poster:
        ({
          required Uri url,
          required Map<String, String> headers,
          required Map<String, Object?> body,
          required CancellationToken token,
        }) async {
          return StreamedBody(statusCode: 200, stream: _chunks(sse, chunkSize));
        },
  );
}

Stream<List<int>> _chunks(String text, int size) async* {
  final List<int> bytes = utf8.encode(text);
  for (int i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, (i + size).clamp(0, bytes.length));
  }
}

ProviderRequest get _req => ProviderRequest(
  model: _model,
  messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
);

void main() {
  group('正文流', () {
    test('文本增量累积成完整消息', () async {
      const String sse = '''
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":12,"output_tokens":0}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"你好"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"，世界"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":8}}

event: message_stop
data: {"type":"message_stop"}

''';
      final List<StreamEvent> events = await apiWith(
        sse,
      ).stream(_req, CancellationToken.none).toList();

      expect(events.first, isA<StreamStart>());
      expect(events.last, isA<StreamDone>());

      final StreamDone done = events.last as StreamDone;
      expect(done.message.text, equals('你好，世界'));
      expect(done.stopReason, equals(StopReason.stop));
      expect(done.message.usage.inputTokens, equals(12));
      expect(done.message.usage.outputTokens, equals(8));
    });

    test('每个事件都带当前完整消息', () async {
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"A"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"B"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"C"}}

''';
      final List<StreamEvent> events = await apiWith(
        sse,
      ).stream(_req, CancellationToken.none).toList();

      final List<StreamTextDelta> deltas = events
          .whereType<StreamTextDelta>()
          .toList();

      expect(deltas.length, equals(3));
      // 增量是单字，但 message 是累积的全文（§4-3）
      expect(deltas[0].delta, equals('A'));
      expect(deltas[0].message.text, equals('A'));
      expect(deltas[1].delta, equals('B'));
      expect(deltas[1].message.text, equals('AB'));
      expect(deltas[2].delta, equals('C'));
      expect(deltas[2].message.text, equals('ABC'));
    });
  });

  group('思考块', () {
    test('thinking 增量与 signature', () async {
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"让我想想"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"def"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"答案"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

''';
      final List<StreamEvent> events = await apiWith(
        sse,
      ).stream(_req, CancellationToken.none).toList();

      final StreamDone done = events.last as StreamDone;
      expect(done.message.thinkingText, equals('让我想想'));
      expect(done.message.text, equals('答案'));

      // signature 分片拼起来，且原样保留
      final ThinkingPart thinking = done.message.parts
          .whereType<ThinkingPart>()
          .single;
      expect(thinking.signature, equals('abcdef'));
      expect(thinking.modelId, equals('claude-sonnet-4-5'));

      expect(events.whereType<StreamThinkingDelta>().length, equals(1));
    });
  });

  group('工具调用', () {
    test('input_json_delta 收全后才解析', () async {
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"toolu_1","name":"read_file"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\\"path\\":"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"\\"a.txt\\"}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

''';
      final List<StreamEvent> events = await apiWith(
        sse,
      ).stream(_req, CancellationToken.none).toList();

      final List<StreamToolCallDelta> deltas = events
          .whereType<StreamToolCallDelta>()
          .toList();
      expect(deltas.length, equals(2));
      expect(deltas[0].toolName, equals('read_file'));
      expect(deltas[0].callId, equals('toolu_1'));
      // 第一个 delta 时 JSON 还不完整，参数是空的——不猜、不报错
      expect(deltas[0].message.toolCalls.single.arguments, isEmpty);

      final StreamDone done = events.last as StreamDone;
      expect(done.stopReason, equals(StopReason.toolUse));

      final ToolCallPart call = done.message.toolCalls.single;
      expect(call.id, equals('toolu_1'));
      expect(call.name, equals('read_file'));
      expect(call.arguments, equals(<String, Object?>{'path': 'a.txt'}));
    });

    test('多个工具调用按 index 排序', () async {
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c1","name":"first"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"c2","name":"second"}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{}"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"tool_use"}}

''';
      final StreamDone done =
          (await apiWith(
                sse,
              ).stream(_req, CancellationToken.none).toList()).last
              as StreamDone;

      expect(done.message.toolCalls.length, equals(2));
      expect(done.message.toolCalls[0].name, equals('first'));
      expect(done.message.toolCalls[1].name, equals('second'));
    });
  });

  group('停止原因映射', () {
    Future<StopReason> reasonFor(String raw) async {
      final String sse =
          '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"x"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"$raw"}}

''';
      final StreamDone done =
          (await apiWith(
                sse,
              ).stream(_req, CancellationToken.none).toList()).last
              as StreamDone;
      return done.stopReason;
    }

    test('end_turn → stop', () async {
      expect(await reasonFor('end_turn'), equals(StopReason.stop));
    });

    test('tool_use → toolUse', () async {
      expect(await reasonFor('tool_use'), equals(StopReason.toolUse));
    });

    test('max_tokens → length', () async {
      // 关键映射：length 意味着整批工具都不能执行（§5-9）
      expect(await reasonFor('max_tokens'), equals(StopReason.length));
    });

    test('stop_sequence → stop', () async {
      expect(await reasonFor('stop_sequence'), equals(StopReason.stop));
    });

    test('缺少 stop_reason 时按有无工具推断', () async {
      const String noReason = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"c","name":"t"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{}"}}

''';
      final StreamDone done =
          (await apiWith(
                noReason,
              ).stream(_req, CancellationToken.none).toList()).last
              as StreamDone;
      expect(done.stopReason, equals(StopReason.toolUse));
    });
  });

  group('缓存用量可观测（§6-12）', () {
    test('cache_read 与 cache_creation 分别读出', () async {
      const String sse = '''
event: message_start
data: {"type":"message_start","message":{"usage":{"input_tokens":5,"cache_read_input_tokens":1800,"cache_creation_input_tokens":240}}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":30}}

''';
      final StreamDone done =
          (await apiWith(
                sse,
              ).stream(_req, CancellationToken.none).toList()).last
              as StreamDone;

      expect(done.message.usage.cacheReadTokens, equals(1800));
      expect(done.message.usage.cacheWriteTokens, equals(240));
      expect(done.message.usage.inputTokens, equals(5));
      expect(done.message.usage.outputTokens, equals(30));
    });
  });

  group('失败路径：永不抛异常（§4-2）', () {
    test('API 返回 error 事件', () async {
      const String sse = '''
event: error
data: {"type":"error","error":{"type":"overloaded_error","message":"服务过载"}}

''';
      final List<StreamEvent> events = await apiWith(
        sse,
      ).stream(_req, CancellationToken.none).toList();

      final StreamDone done = events.last as StreamDone;
      expect(done.isError, isTrue);
      expect(done.stopReason, equals(StopReason.error));
      expect(done.message.errorMessage, equals('服务过载'));
    });

    test('传输层抛错也变成 StreamDone', () async {
      final AnthropicApi api = AnthropicApi(
        apiKey: 'k',
        poster:
            ({
              required Uri url,
              required Map<String, String> headers,
              required Map<String, Object?> body,
              required CancellationToken token,
            }) async {
              throw const ApiError('限流', statusCode: 429);
            },
      );

      // 关键：不抛异常，失败编码进事件
      final List<StreamEvent> events = await api
          .stream(_req, CancellationToken.none)
          .toList();

      expect(events.length, equals(1));
      final StreamDone done = events.single as StreamDone;
      expect(done.isError, isTrue);
      expect(done.message.errorMessage, equals('限流'));
    });

    test('半个 JSON 的事件被跳过而不是让整流失败', () async {
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"broken json

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

''';
      final StreamDone done =
          (await apiWith(
                sse,
              ).stream(_req, CancellationToken.none).toList()).last
              as StreamDone;

      expect(done.stopReason, equals(StopReason.stop));
      expect(done.message.text, equals('ok'));
    });

    test('取消时给 aborted 而不是抛 CancelledException', () async {
      final CancellationTokenSource source = CancellationTokenSource();

      final AnthropicApi api = AnthropicApi(
        apiKey: 'k',
        poster:
            ({
              required Uri url,
              required Map<String, String> headers,
              required Map<String, Object?> body,
              required CancellationToken token,
            }) async {
              throw const CancelledException();
            },
      );

      source.cancel();
      final List<StreamEvent> events = await api
          .stream(_req, source.token)
          .toList();

      final StreamDone done = events.single as StreamDone;
      expect(done.isAborted, isTrue);
      expect(done.stopReason, equals(StopReason.aborted));
    });

    test('流中途取消', () async {
      // 事件之间检查取消：第一个 delta 之后取消，收到 aborted
      final CancellationTokenSource source = CancellationTokenSource();
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"部分"}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"更多"}}

''';
      final List<StreamEvent> collected = <StreamEvent>[];
      await for (final StreamEvent e in apiWith(
        sse,
      ).stream(_req, source.token)) {
        collected.add(e);
        if (e is StreamTextDelta) source.cancel();
      }

      final StreamDone done = collected.last as StreamDone;
      expect(done.isAborted, isTrue);
      // 已经收到的部分内容保留，不丢
      expect(done.message.text, equals('部分'));
    });
  });

  group('streamSimple', () {
    test('返回最终消息', () async {
      const String sse = '''
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"标题"}}

event: message_delta
data: {"type":"message_delta","delta":{"stop_reason":"end_turn"}}

''';
      final ChatMessageModel message = await apiWith(
        sse,
      ).streamSimple(_req, CancellationToken.none);

      expect(message.text, equals('标题'));
      expect(message.stopReason, equals(StopReason.stop));
    });
  });
}
