/// agent 主循环（实施 TODO §5）。
library;

import '../ai/messages.dart';
import '../ai/model_catalog.dart';
import '../ai/provider_api.dart';
import '../ai/stream_event.dart';
import '../core/cancellation_token.dart';
import '../platform/workspace_guard.dart';
import '../state/app_settings.dart';
import '../storage/storage.dart' hide StopReason, TokenUsage;
import '../tools/tool.dart';
import '../tools/tool_registry.dart';
import 'agent_event.dart';
import 'agent_context.dart';

/// 一轮对话的配置。
class AgentConfig {
  const AgentConfig({
    required this.model,
    required this.sessionId,
    required this.workspace,
    this.settings,
    this.storage,
    this.systemPrompt,
    this.maxIterations = 20,
    this.maxOutputTokens,
    this.temperature,
    this.thinkingBudget,
    this.maxTurns,
    this.maxToolCalls,
    this.maxWallTime,
    this.maxOutputTokensTotal,
    this.parallelToolCalls = true,
    this.retryPolicy = const ProviderRetryPolicy(),
  });

  final ModelSpec model;
  final String sessionId;

  /// 这个会话工作区的路径守卫，直接进 [ToolContext]。
  final WorkspaceGuard workspace;
  final AppSettings? settings;

  /// 全局存储，记忆工具需要。
  final WepStorage? storage;

  final String? systemPrompt;

  /// 迭代上限（§5-8）。到了就停，不再发请求。
  ///
  /// 上限存在的理由不是省钱，是防死循环：模型可能反复调同一个失败的工具，
  /// 每次都拿到同样的错误，然后再试一次。
  final int maxIterations;

  final int? maxOutputTokens;
  final double? temperature;
  final int? thinkingBudget;
  final int? maxTurns;
  final int? maxToolCalls;
  final Duration? maxWallTime;
  final int? maxOutputTokensTotal;
  final bool parallelToolCalls;
  final ProviderRetryPolicy retryPolicy;
}

/// 把「一次用户输入」跑成「若干次 API 调用 + 工具执行」。
///
/// 循环结构（§5-1）：
/// 1. 带历史发请求
/// 2. 流式收 assistant 消息
/// 3. 若 `stopReason` 是 toolUse：执行全部工具，结果拼成一条 tool 消息进历史，回到 1
/// 4. 否则结束
class AgentLoop {
  AgentLoop({
    required ProviderApi api,
    required ToolRegistry tools,
    required AgentConfig config,
  }) : _api = api,
       _tools = tools,
       _config = config;

  final ProviderApi _api;
  final ToolRegistry _tools;
  final AgentConfig _config;

  /// 跑一轮。
  ///
  /// [history] 是本轮之前的完整历史（含刚加的用户消息），调用方负责准备。
  /// loop 不改这个列表，新产生的消息通过事件吐出去——谁落库、怎么落库是
  /// 上层的事（§5-3）。
  ///
  /// **不抛异常**：失败编码进 [AgentDone]，和适配器同一条约定（§4-2）。
  Stream<AgentEvent> run(
    List<ChatMessageModel> history,
    CancellationToken token,
  ) async* {
    final List<ChatMessageModel> messages = List<ChatMessageModel>.of(history);
    TokenUsage total = const TokenUsage();
    int toolCallCount = 0;
    final Stopwatch clock = Stopwatch()..start();

    final int turnLimit = _config.maxTurns ?? _config.maxIterations;
    for (int iteration = 1; iteration <= turnLimit; iteration++) {
      if (_config.maxWallTime != null &&
          clock.elapsed >= _config.maxWallTime!) {
        yield AgentDone(
          stopReason: StopReason.error,
          usage: total,
          errorMessage: '达到时间预算',
        );
        return;
      }
      if (token.isCancelled) {
        yield AgentDone(stopReason: StopReason.aborted, usage: total);
        return;
      }

      yield AgentTurnStart(iteration: iteration);

      final AgentContext context = AgentContext(
        systemPromptStable: _config.systemPrompt ?? '',
        tools: _tools.declarations,
        messages: messages
            .where((m) => m.isUsableInHistory)
            .toList(growable: false),
        budget: ContextBudget(
          maxOutputTokensTotal: _config.maxOutputTokensTotal,
        ),
      );
      final CanonicalContext canonical = canonicalizeContext(context);
      final List<ChatMessageModel> transformed = await _api
          .convertToProviderMessages(
            await _api.transformContext(context.messages),
          );
      final ProviderRequest request = ProviderRequest(
        model: _config.model,
        // 丢掉 error / aborted 的轮次（§6-14）：内容不完整，
        // 留着会让模型看到半句话或没有结果的 tool_use。
        messages: transformed,
        systemPrompt: _config.systemPrompt,
        tools: _tools.declarations,
        maxOutputTokens: _config.maxOutputTokens,
        temperature: _config.temperature,
        thinkingBudget: _config.thinkingBudget,
        sessionId: _config.sessionId,
        parallelToolCalls: _config.parallelToolCalls,
        prefixHash: canonical.prefixHash,
      );

      ChatMessageModel? assistant;
      await for (final StreamEvent event in _api.streamWithRetry(
        request,
        token,
        policy: _config.retryPolicy,
      )) {
        switch (event) {
          case StreamStart():
            break;
          case StreamTextDelta(:final String delta):
            yield AgentMessageUpdate(message: event.message, textDelta: delta);
          case StreamThinkingDelta():
            yield AgentMessageUpdate(message: event.message);
          case StreamToolCallDelta():
            yield AgentMessageUpdate(message: event.message);
          case StreamDone():
            assistant = event.message;
        }
      }

      // 适配器保证流一定以 StreamDone 收尾；真没有就是适配器有 bug，
      // 当错误收场而不是继续循环——继续会拿 null 当历史发下一次请求。
      if (assistant == null) {
        yield AgentDone(
          stopReason: StopReason.error,
          usage: total,
          errorMessage: '适配器没有产生结束事件',
        );
        return;
      }

      total = total + assistant.usage;
      messages.add(assistant);
      yield AgentMessageEnd(message: assistant);
      if (_config.maxOutputTokensTotal != null &&
          total.outputTokens > _config.maxOutputTokensTotal!) {
        yield AgentDone(
          stopReason: StopReason.length,
          usage: total,
          errorMessage: '达到总输出 token 预算',
        );
        return;
      }

      final StopReason reason = assistant.stopReason ?? StopReason.stop;

      // arguments 被截断时整批工具都不能执行（§5-9）：参数不完整，
      // 执行等于拿错参数干活。
      if (reason == StopReason.length && assistant.hasToolCalls) {
        final List<ContentPart> truncatedResults = assistant.toolCalls
            .map(
              (ToolCallPart call) => ToolResultPart(
                callId: call.id,
                name: call.name,
                content: '工具调用参数被截断，未执行',
                isError: true,
              ),
            )
            .toList();
        messages.add(
          ChatMessageModel(role: MessageRole.tool, parts: truncatedResults),
        );
        yield AgentDone(
          stopReason: StopReason.length,
          usage: total,
          errorMessage: '工具参数被输出上限截断，本轮工具未执行',
        );
        return;
      }

      if (reason != StopReason.toolUse) {
        yield AgentDone(
          stopReason: reason,
          usage: total,
          errorMessage: assistant.errorMessage,
        );
        return;
      }

      if (_config.maxToolCalls != null &&
          toolCallCount + assistant.toolCalls.length > _config.maxToolCalls!) {
        yield AgentDone(
          stopReason: StopReason.error,
          usage: total,
          errorMessage: '达到工具调用预算',
        );
        return;
      }
      toolCallCount += assistant.toolCalls.length;
      for (final ToolCallPart call in assistant.toolCalls) {
        yield AgentToolStart(call: call);
      }
      final List<ToolResult> toolResults = await Future.wait(
        assistant.toolCalls.map((call) async {
          final ToolResult result = await _tools.dispatch(
            call.name,
            call.arguments,
            ToolContext(
              sessionId: _config.sessionId,
              workspace: _config.workspace,
              token: token,
              settings: _config.settings,
              storage: _config.storage,
            ),
          );

          // 落盘时机：**工具结果每个执行完立刻落盘**（存储设计 §6.1、§9-8）。
          // 不等整轮结束，因为副作用已经发生了——文件真的被写了。中途崩溃
          // 重启后如果磁盘变了而上下文里没有对应的结果，模型会基于错误前提
          // 继续决策。这个事件就是给上层的落盘信号，所以它必须在 `results`
          // 添加之前 yield：上层落完盘，这一条才算数。
          return result;
        }),
      );
      for (int i = 0; i < assistant.toolCalls.length; i++) {
        yield AgentToolEnd(
          call: assistant.toolCalls[i],
          result: toolResults[i],
        );
      }
      final List<ContentPart> results = <ContentPart>[];
      for (int i = 0; i < assistant.toolCalls.length; i++) {
        final ToolCallPart call = assistant.toolCalls[i];
        final ToolResult result = toolResults[i];
        results.add(
          ToolResultPart(
            callId: call.id,
            name: call.name,
            content: result.content,
            isError: result.isError,
          ),
        );
      }

      messages.add(ChatMessageModel(role: MessageRole.tool, parts: results));

      if (token.isCancelled) {
        yield AgentDone(stopReason: StopReason.aborted, usage: total);
        return;
      }
    }

    // 迭代用尽。历史里最后一条是 tool 消息，模型还没就这些结果说话——
    // 界面要能区分这和"模型说完了"（§5-8）。
    yield AgentDone(
      stopReason: StopReason.stop,
      usage: total,
      hitMaxIterations: true,
      errorMessage: '达到迭代上限 ${_config.maxIterations} 次，已停止',
    );
  }
}
