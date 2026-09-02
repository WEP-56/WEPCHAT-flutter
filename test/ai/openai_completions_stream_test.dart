import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/http_transport.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/model_compat.dart';
import 'package:wepchat/ai/openai/openai_completions_api.dart';
import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/ai/stream_event.dart';
import 'package:wepchat/core/cancellation_token.dart';

const ModelSpec _model = ModelSpec(
  id: 'deepseek-chat',
  displayName: 'DeepSeek Chat',
  providerId: 'deepseek',
);

/// 带 reasoning_content 的模型（DeepSeek R1 那类）。
const ModelSpec _thinkingModel = ModelSpec(
  id: 'deepseek-reasoner',
  providerId: 'deepseek',
  compat: ModelCompat(thinking: ThinkingFormat.deepseekReasoningContent),
);

/// 用录好的 SSE 文本建一个适配器。
///
/// 分片大小刻意取小值：真实网络下 SSE 事件会被 TCP 切在任意位置，
/// 按 16 字节切能把"半个事件"的情况逼出来。
OpenAiCompletionsApi apiWith(String sse, {int chunkSize = 16}) {
  return OpenAiCompletionsApi(
    apiKey: 'test-key',
    poster: ({
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

ProviderRequest _req([ModelSpec model = _model]) => ProviderRequest(
      model: model,
      messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
    );

Future<List<StreamEvent>> collect(
  OpenAiCompletionsApi api, [
  ProviderRequest? request,
  CancellationToken? token,
]) {
  return api
      .stream(request ?? _req(), token ?? CancellationToken.none)
      .toList();
}

void main() {
  group('正文流', () {
    test('文本增量累积成完整消息', () async {
      const String sse = '''
data: {"choices":[{"delta":{"content":"你好"}}]}

data: {"choices":[{"delta":{"content":"，世界"}}]}

data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":12,"completion_tokens":4}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect(events.first, isA<StreamStart>());
      final StreamDone done = events.last as StreamDone;
      expect(done.message.text, equals('你好，世界'));
      expect(done.stopReason, equals(StopReason.stop));
      expect(done.message.usage.inputTokens, equals(12));
      expect(done.message.usage.outputTokens, equals(4));
    });

    test('每个事件都带当前完整消息，不只是增量', () async {
      const String sse = '''
data: {"choices":[{"delta":{"content":"一"}}]}

data: {"choices":[{"delta":{"content":"二"}}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final List<StreamTextDelta> deltas =
          events.whereType<StreamTextDelta>().toList();

      expect(deltas.length, equals(2));
      expect(deltas[0].delta, equals('一'));
      expect(deltas[0].message.text, equals('一'));
      expect(deltas[1].delta, equals('二'));
      // 界面据此整条重绘，所以第二个事件必须已经含第一个字。
      expect(deltas[1].message.text, equals('一二'));
    });

    test('服务端没给 finish_reason 时按无工具推断为 stop', () async {
      const String sse = '''
data: {"choices":[{"delta":{"content":"嗯"}}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).stopReason, equals(StopReason.stop));
    });

    test('content 是 null 或数组时跳过，不打断整条流', () async {
      // 兼容端点偶尔在 content 里塞 null 或 part 数组。
      const String sse = '''
data: {"choices":[{"delta":{"content":null}}]}

data: {"choices":[{"delta":{"content":[{"type":"text"}]}}]}

data: {"choices":[{"delta":{"content":"活着"}}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.text, equals('活着'));
    });
  });

  group('思考内容', () {
    test('reasoning_content 进 thinking，不混进正文', () async {
      const String sse = '''
data: {"choices":[{"delta":{"reasoning_content":"先想想"}}]}

data: {"choices":[{"delta":{"content":"答案是 4"}}]}

data: [DONE]

''';
      final List<StreamEvent> events =
          await collect(apiWith(sse), _req(_thinkingModel));
      final StreamDone done = events.last as StreamDone;

      expect(done.message.thinkingText, equals('先想想'));
      expect(done.message.text, equals('答案是 4'));
      expect(events.whereType<StreamThinkingDelta>().length, equals(1));
    });

    test('中转站改名成 reasoning 也认', () async {
      const String sse = '''
data: {"choices":[{"delta":{"reasoning":"换了个字段名"}}]}

data: [DONE]

''';
      final List<StreamEvent> events =
          await collect(apiWith(sse), _req(_thinkingModel));

      expect(
        (events.last as StreamDone).message.thinkingText,
        equals('换了个字段名'),
      );
    });

    test('模型标记为不支持思考时不解析该字段', () async {
      const String sse = '''
data: {"choices":[{"delta":{"reasoning_content":"不该出现"}}]}

data: [DONE]

''';
      // _model 的 compat.thinking 是 none。
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.thinkingText, isEmpty);
    });
  });

  group('工具调用', () {
    test('分片的 arguments 拼完整，id 只在首片出现', () async {
      const String sse = '''
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"read_file","arguments":"{\\"path\\""}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":":\\"a.txt\\"}"}}]}}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final StreamDone done = events.last as StreamDone;

      expect(done.stopReason, equals(StopReason.toolUse));
      final List<ToolCallPart> calls = done.message.toolCalls;
      expect(calls.length, equals(1));
      expect(calls.single.id, equals('call_1'));
      expect(calls.single.name, equals('read_file'));
      // 中途 parse 一定失败，收全了才是合法 JSON（§4-7）。
      expect(calls.single.arguments, equals(<String, Object?>{'path': 'a.txt'}));
    });

    test('两个并行调用按 index 分开，不互相污染', () async {
      const String sse = '''
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c0","function":{"name":"a","arguments":"{\\"x\\":1}"}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":1,"id":"c1","function":{"name":"b","arguments":"{\\"y\\":2}"}}]}}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final List<ToolCallPart> calls =
          (events.last as StreamDone).message.toolCalls;

      expect(calls.length, equals(2));
      expect(calls[0].name, equals('a'));
      expect(calls[0].arguments, equals(<String, Object?>{'x': 1}));
      expect(calls[1].name, equals('b'));
      expect(calls[1].arguments, equals(<String, Object?>{'y': 2}));
    });

    test('index 缺失时按已有数量兜底，第二个调用不覆盖第一个', () async {
      const String sse = '''
data: {"choices":[{"delta":{"tool_calls":[{"id":"c0","function":{"name":"a","arguments":"{}"}}]}}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls"}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.toolCalls.length, equals(1));
    });

    test('length：参数被截断，整批工具都不能执行（§5-9）', () async {
      const String sse = '''
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c0","function":{"name":"a","arguments":"{\\"path\\":\\"很长"}}]}}]}

data: {"choices":[{"delta":{},"finish_reason":"length"}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      // length 单独一档，不能当成 toolUse 去执行那半个调用。
      expect((events.last as StreamDone).stopReason, equals(StopReason.length));
    });
  });

  group('失败路径', () {
    test('流中间的 error 编码进 StreamDone，不抛异常（§4-2）', () async {
      const String sse = '''
data: {"choices":[{"delta":{"content":"开头"}}]}

data: {"error":{"message":"rate limit exceeded"}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final StreamDone done = events.last as StreamDone;

      expect(done.isError, isTrue);
      expect(done.message.errorMessage, equals('rate limit exceeded'));
      // 已经吐出来的半句话留着，界面要显示"错在哪一步"。
      expect(done.message.text, equals('开头'));
    });

    test('content_filter 归为 error', () async {
      const String sse = '''
data: {"choices":[{"delta":{},"finish_reason":"content_filter"}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).isError, isTrue);
    });

    test('非 JSON 的 data 行跳过', () async {
      const String sse = '''
data: 这不是 JSON

data: {"choices":[{"delta":{"content":"好的"}}]}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.text, equals('好的'));
    });

    test('取消：最终事件是 aborted，已收到的文字保留', () async {
      const String sse = '''
data: {"choices":[{"delta":{"content":"一"}}]}

data: {"choices":[{"delta":{"content":"二"}}]}

data: {"choices":[{"delta":{"content":"三"}}]}

data: [DONE]

''';
      final CancellationTokenSource source = CancellationTokenSource();
      final List<StreamEvent> events = <StreamEvent>[];

      await for (final StreamEvent e
          in apiWith(sse).stream(_req(), source.token)) {
        events.add(e);
        if (e is StreamTextDelta && e.message.text == '一') source.cancel();
      }

      final StreamDone done = events.last as StreamDone;
      expect(done.isAborted, isTrue);
      expect(done.message.text, startsWith('一'));
    });
  });

  group('usage', () {
    test('缓存命中数从 prompt_tokens_details 里取', () async {
      const String sse = '''
data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":80}}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final TokenUsage usage = (events.last as StreamDone).message.usage;

      expect(usage.inputTokens, equals(100));
      expect(usage.cacheReadTokens, equals(80));
      // openai 系没有"写缓存"这个计费项。
      expect(usage.cacheWriteTokens, equals(0));
    });

    test('reasoning_tokens 从 completion_tokens_details 里取', () async {
      const String sse = '''
data: {"choices":[{"delta":{},"finish_reason":"stop"}],"usage":{"completion_tokens":50,"completion_tokens_details":{"reasoning_tokens":40}}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect(
        (events.last as StreamDone).message.usage.reasoningTokens,
        equals(40),
      );
    });
  });
}
