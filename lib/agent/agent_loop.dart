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
    this.takePendingInputs,
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

  /// 取走排队中的用户输入（排队式引导，协议 §10.4）。
  ///
  /// loop 在可以安全插话的检查点调用它：即将发请求之前，以及模型本来要
  /// 收场之前。返回空列表表示没有插话。
  ///
  /// **取走即用**：返回的这批会被立刻并进历史并发注入事件，loop 不会替你
  /// 存着（存着就有"取出来了却因为取消而没送出去"的空窗期）。所以队列里
  /// 的东西一旦返回就等于交给了 loop。
  ///
  /// 队列不由 loop 持有：谁在跑、界面怎么显示、条目落到哪都是会话状态，
  /// loop 只负责在正确的时机把它取过来并进历史。为 null 就是不支持插话。
  final List<ChatMessageModel> Function()? takePendingInputs;
}

/// 把「一次用户输入」跑成「若干次 API 调用 + 工具执行」。
///
/// 循环结构（§5-1）：
/// 1. 把排队中的用户输入并进历史（排队式引导，协议 §10.4）
/// 2. 带历史发请求
/// 3. 流式收 assistant 消息
/// 4. 若 `stopReason` 是 toolUse：执行全部工具，结果拼成一条 tool 消息进历史，回到 1
/// 5. 否则结束
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

      // 插话注入点（协议 §10.4）：用户在上一批工具执行期间打的话，到这里
      // 才并进历史。工具已经全部跑完，模型看到的是一个完整的工具结果 +
      // 一句新要求，可以继续，也可以据此重新规划。
      //
      // 取走之后**立刻**并进历史并发注入事件：不能攒着等下一轮开头再注入，
      // 那样中间的取消/超时会让这一批"已经出队却没人用"——界面上的排队标记
      // 已经撤了，模型却没看见（见 _takeSteering 的注释）。
      final List<ChatMessageModel> injected =
          _config.takePendingInputs?.call() ?? const <ChatMessageModel>[];
      for (final ChatMessageModel message in injected) {
        messages.add(message);
        yield AgentInputInjected(message: message, iteration: iteration);
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
        // 用户按了停止：用户自己的动作优先于任何收场判词，直接以中断收尾。
        if (token.isCancelled) {
          yield AgentDone(stopReason: StopReason.aborted, usage: total);
          return;
        }
        // 该收场了，但先看一眼队列：用户可能正好在这批工具跑完时插了话，
        // 有就带上去下一轮（协议 §10.4），没有才真的收场。
        final List<ChatMessageModel>? pending = _takeSteering(
          iteration: iteration,
          turnLimit: turnLimit,
        );
        if (pending != null) {
          for (final ChatMessageModel message in pending) {
            messages.add(message);
            yield AgentInputInjected(
              message: message,
              iteration: iteration + 1,
            );
          }
          continue;
        }
        yield AgentDone(
          stopReason: StopReason.length,
          usage: total,
          errorMessage: '工具参数被输出上限截断，本轮工具未执行',
        );
        return;
      }

      if (reason != StopReason.toolUse) {
        if (token.isCancelled) {
          yield AgentDone(stopReason: StopReason.aborted, usage: total);
          return;
        }
        final List<ChatMessageModel>? pending = _takeSteering(
          iteration: iteration,
          turnLimit: turnLimit,
        );
        if (pending != null) {
          for (final ChatMessageModel message in pending) {
            messages.add(message);
            yield AgentInputInjected(
              message: message,
              iteration: iteration + 1,
            );
          }
          continue;
        }
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
      final Map<int, ToolResult> toolResults = <int, ToolResult>{};
      final Stream<(int, ToolResult)> completions =
          Stream<(int, ToolResult)>.fromFutures(
            assistant.toolCalls.indexed.map((indexedCall) async {
              final (int index, ToolCallPart call) = indexedCall;
              final ToolResult result = await _tools.dispatch(
                call.name,
                call.arguments,
                ToolContext(
                  sessionId: _config.sessionId,
                  callId: call.id,
                  workspace: _config.workspace,
                  token: token,
                  settings: _config.settings,
                  storage: _config.storage,
                ),
              );

              return (index, result);
            }),
          );
      // Emit each completion immediately; a slow MCP request must not delay
      // persisting another tool's already-applied side effect.
      await for (final (int index, ToolResult result) in completions) {
        toolResults[index] = result;
        yield AgentToolEnd(call: assistant.toolCalls[index], result: result);
      }
      final List<ContentPart> results = <ContentPart>[];
      for (int i = 0; i < assistant.toolCalls.length; i++) {
        final ToolCallPart call = assistant.toolCalls[i];
        final ToolResult result = toolResults[i]!;
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

  /// 模型本来要收场时，再查一次插话队列（协议 §10.4）。
  ///
  /// 取到就返回那一批，调用方就地并进历史、发注入事件，然后进入下一轮；
  /// 返回 null 表示"没人插话（或此刻不该取），该收场了"。
  ///
  /// 最后一轮不取：取出来也没有下一轮能注入，消息会从这一轮凭空消失。这种
  /// 情况留在队列里交给会话层收尾——条目在按下发送时就已经落库，下次读历史
  /// 自然会带上，会话层还会给用户一句"没赶上这一轮"的提示（见
  /// `session_generation.dart` 的 finally）。
  List<ChatMessageModel>? _takeSteering({
    required int iteration,
    required int turnLimit,
  }) {
    if (iteration >= turnLimit) return null;
    final List<ChatMessageModel> pending =
        _config.takePendingInputs?.call() ?? const <ChatMessageModel>[];
    return pending.isEmpty ? null : pending;
  }
}
