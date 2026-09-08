import 'dart:async';
import 'dart:io';

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

class _BatchApi extends ProviderApi {
  final List<ProviderRequest> requests = <ProviderRequest>[];

  @override
  Stream<StreamEvent> stream(
    ProviderRequest request,
    CancellationToken token,
  ) async* {
    requests.add(request);
    yield StreamDone(
      message: requests.length == 1
          ? const ChatMessageModel(
              role: MessageRole.assistant,
              parts: <ContentPart>[
                ToolCallPart(
                  id: 'slow-id',
                  name: 'slow',
                  arguments: <String, Object?>{},
                ),
                ToolCallPart(
                  id: 'fast-id',
                  name: 'fast',
                  arguments: <String, Object?>{},
                ),
              ],
              stopReason: StopReason.toolUse,
            )
          : const ChatMessageModel(
              role: MessageRole.assistant,
              parts: <ContentPart>[TextPart('完成')],
              stopReason: StopReason.stop,
            ),
    );
  }
}

class _DeferredTool extends Tool {
  _DeferredTool(String name, this.result)
    : definition = ToolDefinition(
        name: name,
        description: name,
        schema: const <String, Object?>{'type': 'object'},
      );
  @override
  final ToolDefinition definition;
  final Future<ToolResult> result;

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) => result;
}

void main() {
  test('快工具先发完成事件，下一轮结果仍按原调用顺序配对', () async {
    final _BatchApi api = _BatchApi();
    final Completer<ToolResult> slow = Completer<ToolResult>();
    final Completer<void> fastFinished = Completer<void>();
    final AgentLoop loop = AgentLoop(
      api: api,
      tools: ToolRegistry(<Tool>[
        _DeferredTool('slow', slow.future),
        _DeferredTool('fast', Future<ToolResult>.value(ToolResult.ok('fast'))),
      ]),
      config: AgentConfig(
        model: const ModelSpec(
          id: 'fake',
          providerId: 'fake',
          displayName: 'Fake',
          contextWindow: 10000,
          maxOutputTokens: 1000,
        ),
        sessionId: 'session',
        workspace: WorkspaceGuard(Directory.systemTemp.path),
      ),
    );
    final Future<List<AgentEvent>> events = loop
        .run(const <ChatMessageModel>[
          ChatMessageModel(
            role: MessageRole.user,
            parts: <ContentPart>[TextPart('开始')],
          ),
        ], CancellationToken.none)
        .map((AgentEvent event) {
          if (event is AgentToolEnd && event.call.id == 'fast-id') {
            fastFinished.complete();
          }
          return event;
        })
        .toList();
    try {
      await fastFinished.future.timeout(const Duration(seconds: 2));
      expect(slow.isCompleted, isFalse);
    } finally {
      slow.complete(ToolResult.ok('slow'));
    }
    final List<AgentToolEnd> ends = (await events)
        .whereType<AgentToolEnd>()
        .toList();
    expect(ends.map((AgentToolEnd e) => e.call.id), <String>[
      'fast-id',
      'slow-id',
    ]);
    final List<ToolResultPart> results = api.requests.last.messages.last.parts
        .whereType<ToolResultPart>()
        .toList();
    expect(results.map((ToolResultPart p) => p.callId), <String>[
      'slow-id',
      'fast-id',
    ]);
  });
}
