import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/agent/agent_event.dart';
import 'package:wepchat/agent/agent_loop.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/ai/stream_event.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/tools/echo_tool.dart';
import 'package:wepchat/tools/tool.dart';
import 'package:wepchat/tools/tool_registry.dart';

/// 按脚本回放的假适配器。
///
/// 每次 [stream] 调用取脚本的下一条，同时记录收到的请求——loop 有没有把
/// 工具结果正确拼进历史，只能从"下一次请求里有什么"看出来。
class _ScriptedApi extends ProviderApi {
  _ScriptedApi(this._script);

  final List<ChatMessageModel> _script;
  final List<ProviderRequest> requests = <ProviderRequest>[];
  int _index = 0;

  @override
  Stream<StreamEvent> stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    requests.add(request);

    if (_index >= _script.length) {
      throw StateError('脚本用尽，loop 发了比预期更多的请求');
    }
    final ChatMessageModel finalMessage = _script[_index++];

    yield StreamStart(
      message: const ChatMessageModel(
        role: MessageRole.assistant,
        parts: <ContentPart>[],
      ),
    );

    final String text = finalMessage.parts
        .whereType<TextPart>()
        .map((TextPart p) => p.text)
        .join();
    if (text.isNotEmpty) {
      yield StreamTextDelta(message: finalMessage, delta: text);
    }

    yield StreamDone(message: finalMessage);
  }
}

/// 完全不产生 StreamDone 的坏适配器。
class _NoDoneApi extends ProviderApi {
  @override
  Stream<StreamEvent> stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    yield StreamStart(
      message: const ChatMessageModel(
        role: MessageRole.assistant,
        parts: <ContentPart>[],
      ),
    );
  }
}

/// 记录自己被调用过几次的工具。
class _CountingTool extends Tool {
  _CountingTool();

  int calls = 0;

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'count',
        description: '计数',
        schema: <String, Object?>{'type': 'object'},
      );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    calls++;
    return ToolResult.ok('第 $calls 次');
  }
}

void main() {
  const ModelSpec model = ModelSpec(
    id: 'fake-model',
    providerId: 'fake',
    displayName: 'Fake',
    contextWindow: 200000,
    maxOutputTokens: 8192,
  );

  AgentConfig configWith({int maxIterations = 20}) => AgentConfig(
        model: model,
        sessionId: 'session-1',
        workspaceRoot: '/tmp/ws',
        maxIterations: maxIterations,
      );

  ChatMessageModel assistantText(String text, {TokenUsage? usage}) {
    return ChatMessageModel(
      role: MessageRole.assistant,
      parts: <ContentPart>[TextPart(text)],
      stopReason: StopReason.stop,
      usage: usage ?? const TokenUsage(),
    );
  }

  ChatMessageModel assistantToolCall(
    String toolName,
    Map<String, Object?> args, {
    String callId = 'call-1',
    StopReason reason = StopReason.toolUse,
    TokenUsage? usage,
  }) {
    return ChatMessageModel(
      role: MessageRole.assistant,
      parts: <ContentPart>[
        ToolCallPart(id: callId, name: toolName, arguments: args),
      ],
      stopReason: reason,
      usage: usage ?? const TokenUsage(),
    );
  }

  final List<ChatMessageModel> userHistory = <ChatMessageModel>[
    ChatMessageModel.user('你好'),
  ];

  group('无工具的单轮', () {
    test('模型直接回答就结束，只发一次请求', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('你好呀'),
      ]);
      final AgentLoop loop = AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(),
      );

      final List<AgentEvent> events =
          await loop.run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(1));
      expect(events.whereType<AgentTurnStart>().length, equals(1));
      expect(events.whereType<AgentMessageEnd>().length, equals(1));
      expect(events.whereType<AgentToolStart>(), isEmpty);

      final AgentDone done = events.last as AgentDone;
      expect(done.stopReason, equals(StopReason.stop));
      expect(done.hitMaxIterations, isFalse);
    });

    test('空注册表不带 tools 声明', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);
      await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.single.tools, isEmpty);
    });
  });

  group('工具调用', () {
    test('toolUse 后执行工具、拼进历史、再发一次请求', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantToolCall('echo', <String, Object?>{'message': 'hi'}),
        assistantText('工具说 Echo: hi'),
      ]);
      final AgentLoop loop = AgentLoop(
        api: api,
        tools: ToolRegistry(const <Tool>[EchoTool()]),
        config: configWith(),
      );

      final List<AgentEvent> events =
          await loop.run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(2));

      final AgentToolEnd toolEnd = events.whereType<AgentToolEnd>().single;
      expect(toolEnd.result.isError, isFalse);
      expect(toolEnd.result.content, equals('Echo: hi'));

      // 第二次请求的历史：user, assistant(tool_use), tool(tool_result)
      final List<ChatMessageModel> second = api.requests[1].messages;
      expect(second.length, equals(3));
      expect(second[2].role, equals(MessageRole.tool));

      final ToolResultPart part =
          second[2].parts.whereType<ToolResultPart>().single;
      expect(part.callId, equals('call-1'));
      expect(part.content, equals('Echo: hi'));
      expect(part.isError, isFalse);

      expect((events.last as AgentDone).stopReason, equals(StopReason.stop));
    });

    test('每个 tool_use 都配一个 tool_result，数量对得上', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        ChatMessageModel(
          role: MessageRole.assistant,
          parts: const <ContentPart>[
            ToolCallPart(
              id: 'a',
              name: 'echo',
              arguments: <String, Object?>{'message': '1'},
            ),
            ToolCallPart(
              id: 'b',
              name: 'echo',
              arguments: <String, Object?>{'message': '2'},
            ),
          ],
          stopReason: StopReason.toolUse,
        ),
        assistantText('都做完了'),
      ]);

      await AgentLoop(
        api: api,
        tools: ToolRegistry(const <Tool>[EchoTool()]),
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      final List<ToolResultPart> parts = api.requests[1].messages.last.parts
          .whereType<ToolResultPart>()
          .toList();
      expect(parts.length, equals(2));
      expect(parts.map((ToolResultPart p) => p.callId), equals(<String>['a', 'b']));
    });

    test('未知工具名不中断 loop，错误回传给模型', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantToolCall('nonexistent', <String, Object?>{}),
        assistantText('抱歉，我用错了工具'),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry(const <Tool>[EchoTool()]),
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(2));

      final AgentToolEnd end = events.whereType<AgentToolEnd>().single;
      expect(end.result.isError, isTrue);

      final ToolResultPart part = api.requests[1].messages.last.parts
          .whereType<ToolResultPart>()
          .single;
      expect(part.isError, isTrue);
      expect(part.content, contains('echo'));
    });

    test('工具声明按字典序进请求体', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);
      await AgentLoop(
        api: api,
        tools: ToolRegistry(<Tool>[_CountingTool(), const EchoTool()]),
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      expect(
        api.requests.single.tools.map((ToolDefinition d) => d.name).toList(),
        equals(<String>['count', 'echo']),
      );
    });
  });

  group('终止条件', () {
    test('撞迭代上限时标记 hitMaxIterations', () async {
      // 每轮都调工具，永不收口。
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        for (int i = 0; i < 3; i++)
          assistantToolCall('count', <String, Object?>{}, callId: 'c$i'),
      ]);
      final _CountingTool tool = _CountingTool();

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry(<Tool>[tool]),
        config: configWith(maxIterations: 3),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(3));
      expect(tool.calls, equals(3));

      final AgentDone done = events.last as AgentDone;
      expect(done.hitMaxIterations, isTrue);
      expect(done.errorMessage, contains('3'));
    });

    test('工具参数被截断时不执行工具', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantToolCall(
          'count',
          <String, Object?>{},
          reason: StopReason.length,
        ),
      ]);
      final _CountingTool tool = _CountingTool();

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry(<Tool>[tool]),
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      expect(tool.calls, equals(0));
      expect(events.whereType<AgentToolStart>(), isEmpty);

      final AgentDone done = events.last as AgentDone;
      expect(done.stopReason, equals(StopReason.length));
      expect(done.errorMessage, contains('截断'));
    });

    test('开始前就已取消则一个请求都不发', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('不该被调用'),
      ]);
      final CancellationTokenSource source = CancellationTokenSource();
      source.cancel();

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(),
      ).run(userHistory, source.token).toList();

      expect(api.requests, isEmpty);
      expect((events.single as AgentDone).stopReason,
          equals(StopReason.aborted));
    });

    test('适配器不产生 StreamDone 时当错误收场，不继续循环', () async {
      final List<AgentEvent> events = await AgentLoop(
        api: _NoDoneApi(),
        tools: ToolRegistry.empty,
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      final AgentDone done = events.last as AgentDone;
      expect(done.stopReason, equals(StopReason.error));
      expect(done.errorMessage, contains('结束事件'));
    });
  });

  group('用量累计', () {
    test('多轮用量相加', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantToolCall(
          'echo',
          <String, Object?>{'message': 'x'},
          usage: const TokenUsage(inputTokens: 100, outputTokens: 20),
        ),
        assistantText(
          '好了',
          usage: const TokenUsage(inputTokens: 150, outputTokens: 30),
        ),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry(const <Tool>[EchoTool()]),
        config: configWith(),
      ).run(userHistory, CancellationToken.none).toList();

      final AgentDone done = events.last as AgentDone;
      expect(done.usage.inputTokens, equals(250));
      expect(done.usage.outputTokens, equals(50));
    });
  });

  group('历史过滤', () {
    test('error / aborted 的轮次不进下一次请求', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);

      final List<ChatMessageModel> dirty = <ChatMessageModel>[
        ChatMessageModel.user('第一问'),
        const ChatMessageModel(
          role: MessageRole.assistant,
          parts: <ContentPart>[TextPart('半句话')],
          stopReason: StopReason.error,
          errorMessage: '网络断了',
        ),
        ChatMessageModel.user('第二问'),
      ];

      await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(),
      ).run(dirty, CancellationToken.none).toList();

      final List<ChatMessageModel> sent = api.requests.single.messages;
      expect(sent.length, equals(2));
      expect(sent.every((ChatMessageModel m) => m.stopReason != StopReason.error),
          isTrue);
    });
  });
}
