完成了对 `lib/agent`、`lib/ai`、`lib/tools`、`lib/core` 及 `example/pi/packages/agent` 的快速审阅。当前实现已经有不错的纯 Dart 基础：领域消息与 UI 模型分离、Provider 流事件统一、工具结果四态、权限门集中处理、工作区路径守卫、工具声明排序和缓存字段意识都比较清晰。

最值得优先改进的是下面几组底层积木。

**1. 模型协议与事件适配**

当前 `ProviderApi` 和 `StreamEvent` 的方向正确，但建议进一步拆成三层：

```text
ProviderTransport
  HTTP / SSE / WebSocket / 重试 / 超时 / 原始响应

ProviderAdapter
  OpenAI / Anthropic / 其它协议转换

ModelStreamNormalizer
  统一成 start / delta / tool_call / done / error
```

目前适配器必须遵守“永不抛异常、永不 addError”的契约，这能简化 Loop，但也容易掩盖适配器 bug。建议引入结构化的 `ProviderFailure`：

```dart
sealed class ProviderFailure {
  const ProviderFailure();
}

class NetworkFailure extends ProviderFailure {...}
class AuthenticationFailure extends ProviderFailure {...}
class RateLimitFailure extends ProviderFailure {...}
class InvalidResponseFailure extends ProviderFailure {...}
class CancelledFailure extends ProviderFailure {...}
```

然后 `StreamDone` 携带失败对象，而不是只放字符串。这样 UI、重试策略、日志和模型可见错误可以分别处理。

建议补充协议级不变量检查：

- `start` 只能出现一次；
- `done` 只能出现一次且必须是最后事件；
- tool call 的 `id`、名称、参数必须完整；
- `done` 之后再来的事件必须转换成适配器错误；
- 一个 assistant 消息内的 tool call 顺序必须稳定。

`example/pi` 的优势在于把 provider stream 和 agent loop 的职责分得很干净，Dart 版可以保留这种边界。

**2. Agent Loop**

`lib/agent/agent_loop.dart:88-215` 已经实现了最小闭环，但相比 `example/pi` 的 Loop 还缺少几个关键扩展点：

- 没有 `agent_start` / `agent_end` 级别事件；
- 没有 prompt 消息的生命周期事件；
- 没有 steering queue 和 follow-up queue；
- 没有 `prepareNextTurn`；
- 没有 `shouldStopAfterTurn`；
- 没有上下文变换钩子；
- `parallelToolCalls` 字段存在，但当前 Loop 仍然串行执行工具；
- 没有明确的单轮预算、总 token 预算、时间预算；
- 没有重试策略和退避策略。

建议把 Loop 改成显式状态机，而不是只依靠 `for` 循环：

```text
Idle
→ RequestingModel
→ StreamingAssistant
→ ExecutingTools
→ AppendingToolResults
→ PreparingNextTurn
→ Completed / Failed / Cancelled
```

每次状态迁移都产生稳定事件，便于：

- UI 恢复；
- 崩溃后重放；
- 记录 telemetry；
- 测试事件顺序；
- 支持暂停和继续。

当前 `length + toolCalls` 直接结束整轮是安全的，但 `example/pi` 会为每个截断的 tool call 生成对应的错误 tool result，再允许模型重新发起调用。Dart 版建议采用同样策略，否则历史里会留下 assistant tool call，却没有对应的 tool result，恢复或重试时可能不符合部分 provider 的协议要求。

另外，`maxIterations` 只限制模型请求次数，建议同时增加：

```dart
maxTurns
maxToolCalls
maxWallTime
maxInputTokens
maxOutputTokensTotal
```

并为每一种停止原因定义独立枚举。

**3. Tools 实现**

`ToolRegistry` 和 `PermissionGate` 的职责边界很好，但工具参数校验目前仍然分散在每个工具的 `execute` 内部。

建议增加统一的工具调用管线：

```text
decode JSON
→ schema validate
→ normalize arguments
→ permission check
→ cancellation check
→ execute
→ result size limit
→ redact sensitive output
→ structured result
```

每个工具只接收已经验证过的参数对象，例如：

```dart
Future<ToolResult> execute(
  ReadFileArgs args,
  ToolContext context,
);
```

而不是所有工具都接收 `Map<String, Object?>`。如果暂时不引入代码生成，也可以先提供一个轻量 schema validator 和 typed argument parser。

当前工具结果只有文本 `content` 和 UI 专用 `uiPayload`，建议增加结构化字段：

```dart
class ToolResult {
  final ToolOutcome outcome;
  final List<ToolContent> content;
  final Map<String, Object?>? details;
  final bool isRetryable;
  final Duration? retryAfter;
  final String? safeErrorCode;
}
```

这样模型可以看到简短错误，UI 可以看到 diff，Loop 可以决定是否重试。

`ToolRegistry.declarations` 每次调用都会重新排序和创建列表（`lib/tools/tool_registry.dart:86-90`）。建议注册时一次性冻结：

- 工具名排序；
- 声明 canonical JSON；
- 声明 hash；
- 工具版本；
- 权限类别。

工具声明最好支持 `version`，否则修改 schema 后，旧会话恢复时无法判断历史里的 tool call 是否仍兼容。

**4. 工具描述与系统提示词**

当前工具定义的描述主要是字符串，建议把工具描述视作稳定协议，而不是普通文案：

```text
工具名
工具用途
参数语义
副作用
权限要求
失败方式
是否幂等
是否支持并发
输出格式
```

例如文件写入工具应该明确告诉模型：

- 路径必须是工作区相对路径；
- 不允许自行猜测越界路径；
- 已存在文件会覆盖还是拒绝；
- 失败时不要立即重复同一参数；
- 成功后返回摘要，不返回完整文件内容。

系统提示词也建议拆成稳定段和动态段：

```text
Stable prefix:
  身份、行为规范、工具调用规则、安全原则

Capability block:
  当前工具声明、工具版本、模型能力

Session block:
  当前工作区、用户偏好、会话状态

Ephemeral suffix:
  当前时间、临时提醒、单轮约束
```

稳定段必须保持字节级一致，动态信息放在后面。不要把当前时间、随机 ID、临时 UI 状态放入系统提示词前缀。

**5. 安全门**

`PermissionGate` 已经是当前实现中较成熟的部分，但还可以增强：

- 权限决策应带 `toolCallId`，方便审计；
- “本会话允许”最好绑定权限版本，设置变更后自动失效；
- 对高风险工具增加参数级确认，例如删除目录、覆盖文件、执行脚本；
- 用户允许后到工具执行前再次检查取消和权限状态；
- 统一限制工具结果大小，避免模型通过工具输出制造上下文膨胀；
- `ToolRegistry` 中的异常文本不要直接 `'$e'` 返回，可能泄漏内部路径、请求信息或堆栈；
- `run_js` 应单独拥有资源预算：执行时长、输出大小、文件读写次数和内存上限；
- 网络工具需要域名、重定向、响应大小和 MIME 类型限制。

权限状态本身不应写入对话历史，这一点当前实现是正确的。

**6. 上下文结构与缓存命中率**

这是当前最需要系统化建设的部分。`ProviderRequest` 已有 `sessionId` 和工具排序，但还缺少“canonical context”层。

建议增加不可变的 `AgentContext`：

```dart
class AgentContext {
  final String systemPromptStable;
  final String systemPromptDynamic;
  final List<ToolDefinition> tools;
  final List<ChatMessageModel> messages;
  final ContextBudget budget;
  final String contextVersion;
}
```

并提供：

```dart
CanonicalContext canonicalize(AgentContext context);
String computePrefixHash(CanonicalContext context);
```

canonicalization 应统一：

- 工具排序；
- schema key 排序；
- JSON 数字和布尔格式；
- system prompt 分段；
- 消息字段顺序；
- 空字段省略规则；
- thinking block 过滤规则；
- provider-specific message transform。

建议把上下文分成三段：

```text
prefix:
  system + 工具声明 + 固定能力说明

stable history:
  已完成的用户、assistant、tool result

tail:
  当前用户输入、临时上下文、动态状态
```

压缩上下文时优先压缩 `stable history`，不要修改 prefix。每次请求记录：

```text
prefixHash
contextHash
inputTokens
cacheReadTokens
cacheWriteTokens
```

这样才能判断缓存未命中是由于工具声明变化、系统提示词变化、消息规范化变化，还是 provider 本身没有命中缓存。

`example/pi` 的 `transformContext` 和 `convertToLlm` 是很值得移植的两个接口。Dart 版应该在每次 provider 调用前支持：

```dart
transformContext(...)
convertToProviderMessages(...)
```

并要求它们返回结构化错误，而不是静默丢弃消息。

**建议的优先级**

P0：

1. 加统一 schema validator；
2. 增加 Loop 状态和事件不变量检查；
3. 为截断 tool call 生成 tool result；
4. 引入 canonical context 和 prefix hash；
5. 增加总预算与超时；
6. 收敛错误类型，避免直接暴露异常字符串。

P1：

1. 支持并发工具执行，同时保留声明顺序的结果消息；
2. 增加 steering/follow-up；
3. 增加 `transformContext` 和 `convertToProviderMessages`；
4. 工具声明增加版本和能力字段；
5. 权限门支持参数级风险等级。

P2：

1. provider retry/backoff；
2. telemetry schema；
3. transcript replay；
4. 多模型切换时的 thinking/tool compatibility；
5. 工具执行沙箱和资源预算。

总体判断：wepchat 当前已经具备“可工作的 Agent Loop”，下一阶段应从功能堆叠转向协议稳定性、上下文 canonicalization、结构化失败和可重放性。若按上述方向收敛，可以形成一个比完整产品 Agent 更小、更容易教学和复用的纯 Dart agent-core。