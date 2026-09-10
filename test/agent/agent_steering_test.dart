import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/agent/agent_event.dart';
import 'package:wepchat/agent/agent_loop.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/ai/stream_event.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/platform/workspace_guard.dart';
import 'package:wepchat/tools/tool.dart';
import 'package:wepchat/tools/tool_registry.dart';

/// 排队式引导（协议 §10.4）的单元测试。
///
/// 被验证的行为只有一条主线：**用户的话从来不会因为"发晚了"而消失**。
/// 生成期间打进队列的话，要么在下一个安全注入点并进历史，要么留在队列里
/// 交给会话层收尾（条目已经落库）。任何"取走了却没送出去"的中间态都是 bug。
///
/// 用假适配器按脚本回放，看两件事：下一次请求的历史里有什么、事件流里
/// 出现了什么。

/// 按脚本回放的假适配器。
///
/// [onRequest] 在每次请求发出前被调用（`index` 从 0 起），用来模拟"用户
/// 恰好在这个时刻打了字"——这是插话机制唯一的时间维度。
class _ScriptedApi extends ProviderApi {
  _ScriptedApi(this._script, {this.onRequest});

  final List<ChatMessageModel> _script;
  final void Function(int index)? onRequest;
  final List<ProviderRequest> requests = <ProviderRequest>[];
  int _index = 0;

  @override
  Stream<StreamEvent> stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    onRequest?.call(requests.length);
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

/// 执行时回调一下的工具，用来模拟"工具跑的过程中用户打了字"。
class _HookTool extends Tool {
  _HookTool(this.onExecute);

  final void Function() onExecute;
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
    onExecute();
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

  ChatMessageModel assistantText(String text) {
    return ChatMessageModel(
      role: MessageRole.assistant,
      parts: <ContentPart>[TextPart(text)],
      stopReason: StopReason.stop,
    );
  }

  ChatMessageModel assistantToolCall(String toolName) {
    return ChatMessageModel(
      role: MessageRole.assistant,
      parts: <ContentPart>[
        ToolCallPart(id: 'call-1', name: toolName, arguments: <String, Object?>{}),
      ],
      stopReason: StopReason.toolUse,
    );
  }

  /// 一个队列 + 它的取用函数，形态和会话层给 loop 的东西一致。
  ({List<ChatMessageModel> queue, List<ChatMessageModel> Function() take})
  makeQueue() {
    final List<ChatMessageModel> queue = <ChatMessageModel>[];
    return (
      queue: queue,
      take: () {
        final List<ChatMessageModel> taken = List<ChatMessageModel>.of(queue);
        queue.clear();
        return taken;
      },
    );
  }

  AgentConfig configWith({
    required List<ChatMessageModel> Function() take,
    int maxIterations = 20,
  }) {
    return AgentConfig(
      model: model,
      sessionId: 'session-1',
      workspace: WorkspaceGuard('/tmp/ws'),
      maxIterations: maxIterations,
      takePendingInputs: take,
    );
  }

  final List<ChatMessageModel> userHistory = <ChatMessageModel>[
    ChatMessageModel.user('把报告整理一下'),
  ];

  group('工具执行期间的插话', () {
    test('上一批工具跑完才注入，位置在 tool 结果之后', () async {
      final queue = makeQueue();
      // 工具执行期间用户补了一句。
      final _HookTool tool = _HookTool(
        () => queue.queue.add(ChatMessageModel.user('换成 Python')),
      );
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantToolCall('count'),
        assistantText('改成 Python 了'),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry(<Tool>[tool]),
        config: configWith(take: queue.take),
      ).run(userHistory, CancellationToken.none).toList();

      // 插话没有打断工具，工具照常执行完。
      expect(tool.calls, equals(1));
      expect(api.requests.length, equals(2));

      // 第二次请求：user(原话), assistant(tool_use), tool(结果), user(插话)
      final List<ChatMessageModel> second = api.requests[1].messages;
      expect(second.length, equals(4));
      expect(second[2].role, equals(MessageRole.tool));
      expect(second[3].role, equals(MessageRole.user));
      expect(second[3].text, equals('换成 Python'));

      // 队列被取空，事件里带上"注入给了第 2 次请求"。
      expect(queue.queue, isEmpty);
      final AgentInputInjected injected = events
          .whereType<AgentInputInjected>()
          .single;
      expect(injected.iteration, equals(2));
      expect(injected.message.text, equals('换成 Python'));

      // 事件顺序：注入发生在第 2 轮的 turn_start 之前。
      final int injectedAt = events.indexWhere(
        (AgentEvent e) => e is AgentInputInjected,
      );
      final int secondTurn = events.indexWhere(
        (AgentEvent e) => e is AgentTurnStart && e.iteration == 2,
      );
      expect(injectedAt, lessThan(secondTurn));
    });
  });

  group('模型本来要收场时的插话', () {
    test('有排队输入就不收场，再发一次请求', () async {
      final queue = makeQueue();
      // 模型正在说最后一句时，用户插了一句。
      final _ScriptedApi api = _ScriptedApi(
        <ChatMessageModel>[assistantText('报告整理好了'), assistantText('另存一份也做了')],
        onRequest: (int index) {
          if (index == 0) queue.queue.add(ChatMessageModel.user('另存一份'));
        },
      );

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(take: queue.take),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(2));
      expect(api.requests[1].messages.last.text, equals('另存一份'));

      final AgentDone done = events.last as AgentDone;
      expect(done.stopReason, equals(StopReason.stop));
      expect(done.hitMaxIterations, isFalse);

      final AgentInputInjected injected = events
          .whereType<AgentInputInjected>()
          .single;
      expect(injected.iteration, equals(2));
    });

    test('没人插话就正常收场，不多发请求', () async {
      final queue = makeQueue();
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(take: queue.take),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(1));
      expect(events.whereType<AgentInputInjected>(), isEmpty);
      expect((events.last as AgentDone).stopReason, equals(StopReason.stop));
    });

    test('工具参数被截断那条路径也会先看队列', () async {
      final queue = makeQueue();
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        ChatMessageModel(
          role: MessageRole.assistant,
          parts: const <ContentPart>[
            ToolCallPart(id: 'call-1', name: 'count', arguments: <String, Object?>{}),
          ],
          stopReason: StopReason.length,
        ),
        assistantText('好'),
      ], onRequest: (int index) {
        if (index == 0) queue.queue.add(ChatMessageModel.user('先别做了'));
      });
      final _HookTool tool = _HookTool(() {});

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry(<Tool>[tool]),
        config: configWith(take: queue.take),
      ).run(userHistory, CancellationToken.none).toList();

      // 截断的这批工具不执行，但插话照旧带进下一轮。
      expect(tool.calls, equals(0));
      expect(api.requests.length, equals(2));
      expect(api.requests[1].messages.last.text, equals('先别做了'));
      expect(events.whereType<AgentInputInjected>().length, equals(1));
    });
  });

  group('不会吃掉用户的话', () {
    test('到达迭代上限的那一轮不取队列，消息留着', () async {
      final queue = makeQueue();
      // 第一轮就是最后一轮，此时用户插话——取走也没有下一轮能注入。
      final _ScriptedApi api = _ScriptedApi(
        <ChatMessageModel>[assistantText('好')],
        onRequest: (int index) {
          if (index == 0) queue.queue.add(ChatMessageModel.user('等等'));
        },
      );

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(take: queue.take, maxIterations: 1),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(1));
      expect(api.requests.single.messages.length, equals(1));
      expect(queue.queue.length, equals(1)); // 没被取走
      expect(events.whereType<AgentInputInjected>(), isEmpty);
      expect((events.last as AgentDone).hitMaxIterations, isFalse);
    });

    test('用户按了停止就不再取队列，以中断收场', () async {
      final queue = makeQueue();
      final CancellationTokenSource source = CancellationTokenSource();
      final _ScriptedApi api = _ScriptedApi(
        <ChatMessageModel>[assistantText('好')],
        onRequest: (int index) {
          queue.queue.add(ChatMessageModel.user('再补一句'));
          source.cancel();
        },
      );

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(take: queue.take),
      ).run(userHistory, source.token).toList();

      expect((events.last as AgentDone).stopReason, equals(StopReason.aborted));
      expect(api.requests.length, equals(1));
      expect(queue.queue.length, equals(1)); // 留在队列里等会话层收尾
    });
  });

  group('注入时机', () {
    test('还没发第一个请求就有的排队输入，第一轮就带上', () async {
      final queue = makeQueue();
      queue.queue.add(ChatMessageModel.user('还有一点：只要结论'));

      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(take: queue.take),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.single.messages.length, equals(2));
      expect(api.requests.single.messages.last.text, equals('还有一点：只要结论'));
      expect(
        events.whereType<AgentInputInjected>().single.iteration,
        equals(1),
      );
    });

    test('同一检查点排了多条时按先后顺序注入', () async {
      final queue = makeQueue();
      queue.queue.add(ChatMessageModel.user('第一句'));
      queue.queue.add(ChatMessageModel.user('第二句'));

      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: configWith(take: queue.take),
      ).run(userHistory, CancellationToken.none).toList();

      final List<ChatMessageModel> sent = api.requests.single.messages;
      expect(
        sent.map((ChatMessageModel m) => m.text).toList(),
        equals(<String>['把报告整理一下', '第一句', '第二句']),
      );
      expect(
        events
            .whereType<AgentInputInjected>()
            .map((AgentInputInjected e) => e.message.text)
            .toList(),
        equals(<String>['第一句', '第二句']),
      );
    });

    test('没配 takePendingInputs 就是不支持插话，行为与从前一致', () async {
      final _ScriptedApi api = _ScriptedApi(<ChatMessageModel>[
        assistantText('好'),
      ]);

      final List<AgentEvent> events = await AgentLoop(
        api: api,
        tools: ToolRegistry.empty,
        config: AgentConfig(
          model: model,
          sessionId: 'session-1',
          workspace: WorkspaceGuard('/tmp/ws'),
        ),
      ).run(userHistory, CancellationToken.none).toList();

      expect(api.requests.length, equals(1));
      expect(events.whereType<AgentInputInjected>(), isEmpty);
    });
  });
}
