import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/http_transport.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/model_compat.dart';
import 'package:wepchat/ai/openai/openai_responses_api.dart';
import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/ai/stream_event.dart';
import 'package:wepchat/core/cancellation_token.dart';

const ModelSpec _model = ModelSpec(
  id: 'gpt-4o',
  displayName: 'GPT-4o',
  providerId: 'openai',
);

/// 带推理能力的模型（o1 系列）。
const ModelSpec _thinkingModel = ModelSpec(
  id: 'o1-preview',
  providerId: 'openai',
  compat: ModelCompat(thinking: ThinkingFormat.openaiReasoningEffort),
);

/// 用录好的 SSE 文本建一个适配器。
OpenAiResponsesApi apiWith(String sse, {int chunkSize = 16}) {
  return OpenAiResponsesApi(
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

ProviderRequest _req([ModelSpec model = _model]) => ProviderRequest(
  model: model,
  messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
);

Future<List<StreamEvent>> collect(
  OpenAiResponsesApi api, [
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
data: {"type":"response.output_text.delta","delta":"你好"}

data: {"type":"response.output_text.delta","delta":"，世界"}

data: {"type":"response.completed","response":{"usage":{"input_tokens":12,"output_tokens":4}}}

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
data: {"type":"response.output_text.delta","delta":"一"}

data: {"type":"response.output_text.delta","delta":"二"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final List<StreamTextDelta> deltas = events
          .whereType<StreamTextDelta>()
          .toList();

      expect(deltas.length, equals(2));
      expect(deltas[0].delta, equals('一'));
      expect(deltas[0].message.text, equals('一'));
      expect(deltas[1].delta, equals('二'));
      expect(deltas[1].message.text, equals('一二'));
    });

    test('没有工具调用时 stopReason 推断为 stop', () async {
      const String sse = '''
data: {"type":"response.output_text.delta","delta":"嗯"}

data: {"type":"response.completed","response":{}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).stopReason, equals(StopReason.stop));
    });

    test('空 delta 跳过，不打断流', () async {
      const String sse = '''
data: {"type":"response.output_text.delta","delta":""}

data: {"type":"response.output_text.delta","delta":"活着"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.text, equals('活着'));
    });
  });

  group('思考内容', () {
    test('reasoning_summary_text.delta 进 thinking，不混进正文', () async {
      const String sse = '''
data: {"type":"response.reasoning_summary_text.delta","delta":"先想想"}

data: {"type":"response.output_text.delta","delta":"答案是 4"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(
        apiWith(sse),
        _req(_thinkingModel),
      );
      final StreamDone done = events.last as StreamDone;

      expect(done.message.thinkingText, equals('先想想'));
      expect(done.message.text, equals('答案是 4'));
      expect(events.whereType<StreamThinkingDelta>().length, equals(1));
    });

    test('旧版 reasoning_summary.delta 也认', () async {
      const String sse = '''
data: {"type":"response.reasoning_summary.delta","delta":"换了个字段名"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(
        apiWith(sse),
        _req(_thinkingModel),
      );

      expect(
        (events.last as StreamDone).message.thinkingText,
        equals('换了个字段名'),
      );
    });

    test('reasoning_text.delta 也进入思考内容', () async {
      const String sse = '''
data: {"type":"response.reasoning_text.delta","delta":"思考正文"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      expect(
        (events.last as StreamDone).message.thinkingText,
        equals('思考正文'),
      );
    });

    test('模型不支持思考时不累积，但 responses API 无条件解析', () async {
      // responses API 的累积器不看模型标记——因为 o1 的 reasoning 不在流里，
      // 只有 summary 会出现。completions API 才需要按 compat.thinking 过滤。
      const String sse = '''
data: {"type":"response.reasoning_summary_text.delta","delta":"会出现"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      // _model 的 compat.thinking 是 none，但 responses 累积器照收。
      expect((events.last as StreamDone).message.thinkingText, equals('会出现'));
    });
  });

  group('工具调用', () {
    test('分片的 arguments 拼完整，call_id 和 name 在 added 事件', () async {
      const String sse = '''
data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"call_1","name":"read_file"}}

data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"path\\""}

data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":":\\"a.txt\\"}"}

data: {"type":"response.completed","response":{}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final StreamDone done = events.last as StreamDone;

      expect(done.stopReason, equals(StopReason.toolUse));
      final List<ToolCallPart> calls = done.message.toolCalls;
      expect(calls.length, equals(1));
      expect(calls.single.id, equals('call_1'));
      expect(calls.single.name, equals('read_file'));
      expect(
        calls.single.arguments,
        equals(<String, Object?>{'path': 'a.txt'}),
      );
    });

    test('两个并行调用按 output_index 分开', () async {
      const String sse = '''
data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c0","name":"a"}}

data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"x\\":1}"}

data: {"type":"response.output_item.added","output_index":1,"item":{"type":"function_call","call_id":"c1","name":"b"}}

data: {"type":"response.function_call_arguments.delta","output_index":1,"delta":"{\\"y\\":2}"}

data: {"type":"response.completed","response":{}}

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

    test('没见过 added 的 delta 跳过', () async {
      const String sse = '''
data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"orphan\\":1}"}

data: {"type":"response.completed","response":{}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.toolCalls, isEmpty);
    });

    test('incomplete + max_output_tokens 映射成 length（§5-9）', () async {
      const String sse = '''
data: {"type":"response.output_item.added","output_index":0,"item":{"type":"function_call","call_id":"c0","name":"a"}}

data: {"type":"response.function_call_arguments.delta","output_index":0,"delta":"{\\"path\\":\\"很长"}

data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"max_output_tokens"}}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).stopReason, equals(StopReason.length));
    });
  });

  group('失败路径', () {
    test('流中间的 error 事件编码进 StreamDone', () async {
      const String sse = '''
data: {"type":"response.output_text.delta","delta":"开头"}

data: {"type":"error","error":{"message":"rate limit exceeded"}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final StreamDone done = events.last as StreamDone;

      expect(done.isError, isTrue);
      expect(done.message.errorMessage, equals('rate limit exceeded'));
      expect(done.message.text, equals('开头'));
    });

    test('response.failed 归为 error', () async {
      const String sse = '''
data: {"type":"response.failed","response":{}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).isError, isTrue);
    });

    test('incomplete + content_filter 显示本地化错误', () async {
      const String sse = '''
data: {"type":"response.incomplete","response":{"incomplete_details":{"reason":"content_filter"}}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final StreamDone done = events.last as StreamDone;

      expect(done.isError, isTrue);
      expect(done.message.errorMessage, equals('内容被安全策略拦截'));
    });

    test('非 JSON 的 data 行跳过', () async {
      const String sse = '''
data: 这不是 JSON

data: {"type":"response.output_text.delta","delta":"好的"}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));

      expect((events.last as StreamDone).message.text, equals('好的'));
    });

    test('取消：最终事件是 aborted，已收到的文字保留', () async {
      const String sse = '''
data: {"type":"response.output_text.delta","delta":"一"}

data: {"type":"response.output_text.delta","delta":"二"}

data: {"type":"response.output_text.delta","delta":"三"}

data: [DONE]

''';
      final CancellationTokenSource source = CancellationTokenSource();
      final List<StreamEvent> events = <StreamEvent>[];

      await for (final StreamEvent e in apiWith(
        sse,
      ).stream(_req(), source.token)) {
        events.add(e);
        if (e is StreamTextDelta && e.message.text == '一') source.cancel();
      }

      final StreamDone done = events.last as StreamDone;
      expect(done.isAborted, isTrue);
      expect(done.message.text, startsWith('一'));
    });
  });

  group('usage', () {
    test('字段名是 input_tokens / output_tokens', () async {
      const String sse = '''
data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":5}}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final TokenUsage usage = (events.last as StreamDone).message.usage;

      expect(usage.inputTokens, equals(100));
      expect(usage.outputTokens, equals(5));
    });

    test('缓存命中数从 input_tokens_details.cached_tokens 取', () async {
      const String sse = '''
data: {"type":"response.completed","response":{"usage":{"input_tokens":100,"input_tokens_details":{"cached_tokens":80}}}}

data: [DONE]

''';
      final List<StreamEvent> events = await collect(apiWith(sse));
      final TokenUsage usage = (events.last as StreamDone).message.usage;

      expect(usage.inputTokens, equals(100));
      expect(usage.cacheReadTokens, equals(80));
      expect(usage.cacheWriteTokens, equals(0));
    });

    test('reasoning_tokens 从 output_tokens_details 里取', () async {
      const String sse = '''
data: {"type":"response.completed","response":{"usage":{"output_tokens":50,"output_tokens_details":{"reasoning_tokens":40}}}}

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
