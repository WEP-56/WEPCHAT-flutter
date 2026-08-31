# WePChat 实施 TODO

状态：开工计划，逐项勾选

依据：`WePChat-Flutter-功能与工具协议.md`（功能边界，下称"协议"）、`AGENTS.md`（工程约束）、`WePChat-Flutter-会话存储设计.md`（存储，下称"存储文档"）、`example/pi`（实现思路参考，**不复用代码**）

## 0. 阅读结论

### 0.1 当前代码状态

`lib/` 下 55 个 Dart 文件全是 UI、mock 数据和界面状态：`lib/mock/`、`lib/models/`（展示用模型，`ChatMessage.time` 是 `'14:32'` 这样的字符串，`isUser` 是 bool 而非 role，没有 usage/时间戳/持久化）、`lib/state/`（`session_store.dart` 操作内存列表）、`lib/theme/`、`lib/ui/`、`lib/platform/window_controls.dart`。

`pubspec.yaml` **目前零依赖**（只有 flutter、flutter_test、flutter_lints）。协议 §10.3 提到的 `wep_ai` / `wep_agent_core` / `wep_tools` / `wep_storage` / `wep_runtime` **一行都不存在**。第二阶段是全新建设，不是改造。

结论：不要试图给 `lib/models/chat.dart` 加持久化。真实领域模型另建，UI 的展示模型由它派生（M0-6）。

### 0.2 pi 的可用程度

`example/pi` 是清洗后的代码，缺东西。已确认：

- `packages/agent/src/harness/agent-harness.ts`（508 行）几乎全是 `HarnessNotImplemented` 桩，只有 getter/setter 是实的。**它的接口形状可参考，它的行为不可参考。**
- `packages/agent/src/harness/tools/index.ts` 只导出 bash/edit/read/write 四个工具，没有 web/memory/image 工具。
- 可恢复运行协议在 `session/types.ts` 里有完整类型（`step_attempt`、`tool_started`…），但落地代码不完整。

真正完整、值得细读的是：`agent.ts`（有状态包装 + 事件归约）、`harness/tools/edit.ts`（工具形状）、`harness/messages.ts`（自定义角色投影）、`harness/compaction/compaction.ts`（压缩算法）、`harness/session/types.ts`（条目模型）、`harness/session/jsonl/storage.ts`（物理格式，我们不采用）。

**规则：`example/pi` 里的缺失一律视为"代码被删了"，不得当成设计决策。** 需要确认原始行为时查 https://github.com/earendil-works/pi 。

### 0.3 与协议的三处偏离（需用户确认）

| # | 协议原文 | 建议 | 位置 |
|---|---|---|---|
| A | §2.2 记忆存 `memory.json` | 改存 SQLite 表 | 存储文档 §12 |
| B | §10.3 事件里只有 `message_update` | 补 `message_start` / `message_end` | 本文 §5.2 |
| C | §10.3 列出五个模块名 | 第一版做成同一 package 内的目录分层，不拆 pub 包 | 本文 §1 |

C 的理由：拆成本地 pub 包会让每次改动都要动多个 `pubspec.yaml`，而收益（编译隔离、可独立发布）在单 App 项目里拿不到。目录分层同样能强制依赖方向，靠 code review 和 `import` 约定守住。纯 Dart 层（`ai/`、`agent/`、`storage/`）保持不 import `package:flutter/*`，将来要抽包随时能抽。

## 1. 目录与依赖方向

```text
lib/
├── core/         取消、错误、结果类型、ULID、日志脱敏     依赖：无
├── ai/           协议 §10.3 的 wep_ai：三个 API 适配 + 模型目录  依赖：core
├── agent/        wep_agent_core：loop、事件、上下文拼接、压缩   依赖：core, ai, storage
├── tools/        wep_tools：注册表、权限门、各工具实现        依赖：core, storage, runtime
├── storage/      wep_storage：SQLite、DAO、迁移、blob、DB isolate 依赖：core
├── runtime/      wep_runtime：WepJsRuntime + QuickJS FFI      依赖：core
├── platform/     平台差异集中处（协议要求不散落 Platform.is*） 依赖：core
├── models/       UI 展示模型（现有）                          依赖：agent 的领域类型
├── state/        现有界面状态                                 依赖：agent, tools, storage
├── theme/ ui/ app/  现有界面                                  依赖：state, models
```

硬规则（`AGENTS.md` §1.2 §7）：

- [ ] 1-1 `ai/`、`agent/`、`storage/`、`core/` 内**不出现** `import 'package:flutter/...'`。
- [ ] 1-2 箭头只朝下，不出现反向 import；`ui/` 不直接 import `ai/`。
- [ ] 1-3 `Platform.isAndroid` / `isWindows` 只允许出现在 `platform/`。
- [ ] 1-4 单文件 ≤ 800 行，目标 300–600（`AGENTS.md` §2.1）。适配器按 API 分文件，工具一个一文件。

## 2. 依赖新增计划

`pubspec.yaml` 现在是空的，每一项都要按 `AGENTS.md` §8 交代 Android ABI / Windows 打包 / 体积 / 许可 / 维护状态。

| 里程碑 | 包 | 用途 | 需要验证 |
|---|---|---|---|
| M0 | `sqlite3` | DB 的 Dart FFI 绑定 | — |
| M0 | `sqlite3_flutter_libs` | Android `.so` / Windows `.dll` | 四个 ABI + isolate 内加载 + FTS5/trigram 是否编入 |
| M0 | `path_provider` | App 私有目录、AppData | 两平台路径语义 |
| M0 | `crypto` | blob 的 sha256 | 纯 Dart，无风险 |
| M1 | `http` | 流式请求 | SSE 在 Android 上不被缓冲；能中途 abort |
| M2 | `file_picker` 或平台通道 | 附件选择 | Android 13+ 权限模型 |
| M5 | QuickJS 静态库（自建 FFI，非 pub 包） | `run_js` | 四个 ABI 交叉编译 + Windows MSVC 构建 + `dart:ffi` 绑定 |

不引入：drift、freezed、json_serializable、riverpod / bloc、任何 SSE 封装包。理由统一是"生成代码或第三方类型渗透领域层"，以及现有量级不需要。

- [ ] 2-1 逐个包在 Android 真机与 Windows Release 上确认可构建后再进 `pubspec.yaml`，不批量加。
- [ ] 2-2 `sqlite3_flutter_libs` 加入后立刻验证：Android arm64/armv7/x86_64 + Windows Release 打包能找到 native 库。

## 3. `core/`：取消与错误（最先做，别的都依赖它）

Dart 没有 `AbortSignal`，`Future` 也不可取消。协议 §5.3 要求"所有长耗时操作都可取消"，所以取消必须是**显式参数**，一路传到最底层。

- [ ] 3-1 `CancellationToken`：`isCancelled`、`throwIfCancelled()`、`onCancel(cb)`、`Future<void> get whenCancelled`。可从父 token 派生（一轮回复取消 ⇒ 其中所有工具取消）。约 60 行。
- [ ] 3-2 每个可能阻塞的调用都接受 `CancellationToken`：HTTP（`http.Client.close()` 中断流）、文件读写（分块读，块间检查）、QuickJS（`JS_SetInterruptHandler`，见 §8）、DB（长事务前检查）。
- [ ] 3-3 错误体系：`WepError` 基类 + `NetworkError` / `ApiError(status, providerMessage)` / `AuthError` / `ToolError` / `PermissionDeniedError` / `CancelledError` / `StorageError` / `ValidationError`。禁止裸 `Exception('...')`（`AGENTS.md` §1.3）。
- [ ] 3-4 **日志脱敏是一个函数，不是各处自觉**：`redact(String)` 去掉 `sk-*`、`Authorization` 头、绝对路径的用户名段。所有 log 出口只走这一个函数（`AGENTS.md` §1.2 §2.4）。
- [ ] 3-5 ULID 生成（时间前缀 + 随机），会话 id / 条目 id / 工具调用 id 共用。不引入包，约 40 行。
- [ ] 3-6 `Result<T>` 还是抛异常？定：**领域可预期失败用返回值**（工具结果的四态、权限拒绝），**编程错误和不可恢复失败抛异常**。不做全局 Result 化，避免每层都在解包。

## 4. `ai/`：三个 API 适配

协议要求 openai-completions、openai-responses、anthropic-messages 三种。pi 最值得抄的一个决定：**差异用"按模型的兼容标记"表达，不用"按厂商的 if 分支"**。因为同一个 `/v1/chat/completions` 端点后面是 DeepSeek、Kimi、GLM、Qwen、本地 vLLM，它们的差异不在厂商而在模型。

### 4.1 统一契约

- [ ] 4-1 `abstract class ProviderApi`：`Stream<StreamEvent> stream(Request req, CancellationToken t)` + `Future<AssistantMessage> streamSimple(...)`（无工具的一次性调用，给标题生成和压缩摘要用）。
- [ ] 4-2 **`stream` 永不抛异常、永不 `addError`**。失败编码进最终事件：`done` 携带一条 `stopReason: error|aborted` + `errorMessage` 的 `AssistantMessage`。这条是 pi 的核心契约，抄。理由：上层 loop 只处理一种失败路径，不必同时接 try/catch 和事件。
- [ ] 4-3 事件序列固定：`start` → `textDelta` / `thinkingDelta` / `toolCallDelta`（任意交错）→ `done`。每个事件都带**当前完整的 partial `AssistantMessage`**，界面可以直接整条重绘，不用自己拼增量。
- [ ] 4-4 一个共享 SSE 解析器（`ai/sse.dart`），三个适配器都用它。绝不写三份行拆分逻辑（`AGENTS.md` §1.2）。注意：`data: [DONE]`、多行 `data:`、注释行 `:`、`event:` 字段、UTF-8 多字节被切在块边界。

### 4.2 兼容标记（只列第一版真正需要的）

pi 有近 30 个标记，我们不照搬。第一版九个：

```dart
class ModelCompat {
  final String maxTokensField;       // max_tokens | max_completion_tokens
  final bool supportsDeveloperRole;  // 否则 system
  final ThinkingFormat thinking;     // none | openaiReasoningEffort | anthropicThinking
                                     // | deepseekReasoningContent | qwenEnableThinking
  final CacheControlFormat cache;    // none | anthropic
  final bool supportsPromptCacheKey;
  final bool requiresToolResultName; // 少数兼容端点要求 tool result 带 name
  final bool supportsParallelToolCalls;
  final bool visionInput;
  final bool supportsTemperature;    // o 系列拒绝 temperature
}
```

- [ ] 4-5 标记存在模型目录里，不硬编码在适配器里。用户添加自定义模型时能在设置里选这些开关（协议 §8 要求可自定义 provider）。
- [ ] 4-6 新增一个标记必须同时说明"哪个真实模型需要它"。不为假想的模型加标记（`AGENTS.md` §3）。

### 4.3 三个适配器各自的坑

- [ ] 4-7 **openai-completions**：`tool_calls` 的 `index` 字段是拼接依据，`id` 只在第一个 delta 出现；`arguments` 是字符串增量，全部收完才是合法 JSON（中途 parse 一定失败，不要试）；`finish_reason: "length"` 必须映射成 `stopReason: length`（见 §5.3）；思考内容有三种放法（`reasoning_content` / `reasoning` / `<think>` 标签），按标记选。
- [ ] 4-8 **openai-responses**：事件是带 `type` 的具名 JSON（`response.output_text.delta`、`response.function_call_arguments.delta`…），不是 completions 的 choices/delta 结构，解析路径完全独立；工具结果作为 `function_call_output` 项回传；`store: false` 必须显式设，否则请求被留在服务端。
- [ ] 4-9 **anthropic-messages**：`content_block_start/delta/stop` 三段式；`thinking` 块带 `signature`，回传时**必须原样带回**，改一个字节就报错；`input_json_delta` 同样是字符串增量；`tool_result` 是 user 消息里的 block 而不是独立角色；顶层 `system` 是独立字段不是消息。
- [ ] 4-10 重试：只对 429 / 5xx / 连接失败重试，指数退避 + 尊重 `Retry-After`。**首字节到达后不再重试**——已经吐出的文本无法回收，重试会产生重复内容。这条要写进代码注释。
- [ ] 4-11 请求日志只记 method / host / path / status / 耗时。**不记 header、不记 body、不记 key**（`AGENTS.md` §2.4）。

## 5. `agent/`：loop 与事件

### 5.1 两层循环

pi 的结构：外层 follow-up 循环，内层 tool/steering 循环。

```text
agent_start
└─ 外层：只要还有待发消息（用户后续输入 / follow-up）就继续
   └─ turn_start
      └─ 内层：调模型 → 有 tool_use 就执行 → 结果入上下文 → 再调模型
         直到模型不再请求工具，或被中断，或 stopReason=length
      turn_end
agent_end
```

- [ ] 5-1 外层与内层分成两个方法，不要写成一个带三重 `while` 的函数。
- [ ] 5-2 单次运行守卫：同一会话同时只允许一个 run（一个 `activeRun` 字段 + abort token）。第二次 prompt 进队列而不是并发跑。
- [ ] 5-3 队列模式：`all`（一次全灌进去）/ `oneAtATime`（每轮取一条）。默认 `oneAtATime`，与 pi 默认一致。
- [ ] 5-4 用户在生成中途输入的消息走 steering 路径（插到本轮工具结果之后），不打断当前流。

### 5.2 事件（补齐协议 §10.3）

协议列了 `agent_start` / `turn_start` / `message_update` / `tool_execution_start` / `tool_execution_update` / `tool_execution_end` / `turn_end` / `agent_end`。界面需要区分"新气泡出现"和"气泡内容变了"，所以：

- [ ] 5-5 把 `message_update` 拆成 `message_start` / `message_update` / `message_end`。这是偏离 B，需用户确认后回写协议 §10.3。
- [ ] 5-6 事件流是界面的**唯一**输入。界面不去读 storage、不自己算状态（`AGENTS.md` §1.2）。
- [ ] 5-7 一个纯函数式归约器把事件序列变成 `SessionRuntimeState { messages, streamingMessage, pendingToolCalls, lastError }`，参考 pi `agent.ts` 的 `processEvents`。纯函数便于测试。
- [ ] 5-8 订阅者按序 await，异常不吞：某个订阅者抛异常要让 run 失败并上报，不能静默继续（`AGENTS.md` §1.3）。

### 5.3 内层循环的几条硬规则（都来自 pi，都有明确理由）

- [ ] 5-9 `stopReason == "length"` 时**整批工具调用全部不执行**，本轮以错误结束。因为最后一个 tool call 的 arguments 被截断了，JSON 不完整，猜参数等于乱执行。
- [ ] 5-10 有任一工具声明 `sequential` 就整批串行；全是 `readonly` 才并行。协议 §6.2 的"写/编辑/删除必须串行"由此落地。
- [ ] 5-11 `terminate` 只在**所有**工具结果都要求终止时才终止。一个工具说停另一个说继续 ⇒ 继续。
- [ ] 5-12 工具执行前必过权限门（§7.3），拒绝也要**产生一条 tool result** 告诉模型"用户拒绝了"，不能静默跳过——否则模型看到工具调用没有结果，会重试到死。
- [ ] 5-13 钩子（`beforeToolCall` / `afterToolCall` / `shouldStopAfterTurn`）**不得抛异常**，签名上写清，实现里包一层。

## 6. 上下文拼接与缓存命中

这是用户点名要求的重点。核心事实只有一条：**prompt cache 是按请求前缀逐字节匹配的**。前缀里任何一个字节变了，从那个位置往后全部失效。所以规范的目标就是把"每轮都变的东西"全部赶到请求末尾去。

### 6.1 请求的分层：越稳定的放越前面

```text
[ 1 ] system：产品身份 + 工具使用规则 + 输出规范      ——  永不变
[ 2 ] system：启用的工具清单摘要、记忆索引            ——  用户改设置才变
      ↑ cache_control 落点 1（system 末尾）
[ 3 ] tools 定义（按名字排序）
      ↑ cache_control 落点 2（最后一个工具定义）
[ 4 ] 历史消息（压缩点之后，全部不可变）
[ 5 ] 本轮用户消息
      ↑ cache_control 落点 3 / 4（最后一条 user 消息的最后一个 block）
[ 6 ] 易变信息：当前时间、工作区文件树快照
```

- [ ] 6-1 **当前时间绝不进 system prompt**。这是最容易犯又最致命的错：时间每秒都变，system 是前缀最前面，等于每次请求全量 miss。需要时间就放第 6 层（本轮 user 消息末尾），或者干脆不给。
- [ ] 6-2 工作区文件树同理放第 6 层。它每次工具写文件都会变。
- [ ] 6-3 记忆索引放第 2 层可以，因为它只在 `save_memory` 之后变——但要接受"存一条记忆导致本轮 miss"。
- [ ] 6-4 `<available_skills>` 之类的清单用**确定性 XML**：固定字段顺序、固定缩进、按 id 排序。pi 就是这么做的，为的就是前缀稳定。

### 6.2 序列化必须是确定性的

Dart 的 `Map` 是插入序，`jsonEncode` 按插入序输出——这意味着**构造 Map 的代码顺序决定了字节**。重构时挪一行赋值就会打断所有用户的缓存，而且没人会发现。

- [ ] 6-5 请求体不用临时 `Map` 字面量拼，用一个显式的 builder，字段顺序写死并加注释"顺序影响 prompt cache，勿动"。
- [ ] 6-6 工具定义按 `name` 字典序输出，不依赖注册顺序。
- [ ] 6-7 JSON Schema 里的 `properties` 按声明顺序、`required` 数组排序后输出。
- [ ] 6-8 写一个测试：同一 session 状态序列化两次，字节完全相等；改动无关代码后仍与黄金样本相等。这是唯一能防住回归的手段。

### 6.3 两家的缓存开关

- [ ] 6-9 **Anthropic**：`cache_control: {type: "ephemeral"}`，最多四个落点，放在 §6.1 图里标的位置。长保留用 `ttl: "1h"`（需模型支持，走兼容标记）。落点数量超限 API 会直接报错，要有断言。
- [ ] 6-10 **OpenAI**：`prompt_cache_key` 填**会话 id**（截断到 64 字符）。它的作用是把同一会话的请求路由到同一台缓存副本上；填随机值等于关掉缓存。配合 `prompt_cache_retention`（可用时）与 `store: false`。
- [ ] 6-11 OpenAI 兼容端点（DeepSeek / Kimi / GLM）有的接受 Anthropic 风格的 `cache_control`，有的自动缓存不需要参数。由 `ModelCompat.cache` 决定，不做探测（探测意味着不确定行为）。
- [ ] 6-12 界面上要能看到 `cacheRead` / `cacheWrite` token（协议 §8 要求显示用量）。缓存有没有生效必须可观测，否则这一整节的工作无法验证。

### 6.4 规范化必须幂等

跨模型兼容要做一批消息改写（对应 pi 的 `transformMessages`）：非视觉模型降级图片、换模型后丢弃他人的 thinking 块、tool_call id 规范化、丢弃 `stopReason` 为 error/aborted 的 assistant 轮次、给孤立的 tool_use 补一条 `"No result provided"` 结果。

- [ ] 6-13 这个函数必须是**纯函数且幂等**：`f(f(x)) == f(x)`。否则同一段历史两次序列化字节不同，缓存直接失效。写测试卡住。
- [ ] 6-14 丢弃出错轮次靠 `entries.stop_reason` 列判断，不解析 payload（存储文档 §5.2）。
- [ ] 6-15 换模型时的 thinking 块处理：只保留"同一模型产出"的 thinking。模型身份记在 entry payload 里，靠它判断。

### 6.5 压缩与缓存的关系

- [ ] 6-16 压缩阈值：`contextTokens > contextWindow - reserveTokens`，`reserveTokens` 取 16384、`keepRecentTokens` 取 20000（pi 的默认值，量级合理）。
- [ ] 6-17 token 估算 = 最后一条**有效** assistant 消息的 usage + 之后消息的估算（文本 ≈ 字符数/4，图片按固定值约 4800 字符）。"有效"指 `stopReason` 不是 aborted/error。
- [ ] 6-18 **切点永远不能落在 tool_result 之前**——那会留下一个没有结果的 tool_use，多数 API 直接 400。
- [ ] 6-19 压缩那一轮必然全量 miss。所以阈值要留够余量，避免在窗口边缘反复触发（每次都是全量重算）。
- [ ] 6-20 压缩是追加一条 compaction 条目 + 移动 `base_seq`，不动旧条目（存储文档 §7.2）。

## 7. `tools/`：注册与实现

### 7.1 工具形状

参考 pi `harness/tools/edit.ts`，Dart 版：

```dart
abstract class WepTool {
  String get name;              // 稳定，改名等于换工具（协议 §6.2）
  String get label;             // 界面显示
  String get description;       // 进 prompt，影响缓存前缀，改动要谨慎
  Map<String, Object?> get schema;
  ToolExecutionMode get mode;   // readonly | sequential
  Map<String, Object?> prepareArguments(Map<String, Object?> raw);
  Future<ToolResult> execute(String callId, Map<String, Object?> args,
      CancellationToken token, void Function(ToolUpdate) onUpdate, ToolEnv env);
}
```

- [ ] 7-1 `prepareArguments` 容错，`execute` 严格。模型经常把数组塞成 JSON 字符串、把嵌套字段拍平——这些在 `prepareArguments` 里修，`execute` 拿到的必须已经是规范形状。pi 的 edit 工具就同时接受 `edits` 为字符串和顶层的 `oldText`/`newText`。
- [ ] 7-2 校验在**工具入口一次**完成（`AGENTS.md` §4）。写一个受限 JSON Schema 校验器：object / string / number / integer / boolean / array / enum / required / 描述。**不支持** `oneOf` / `anyOf` / `$ref` / 递归——协议 §6.2 本来就要求用各家都支持的子集，校验器只需覆盖这个子集。约 150 行，不引包。
- [ ] 7-3 `ToolResult` 四态必须能区分（`AGENTS.md` §4）：成功、业务失败（文件不存在）、被取消、权限拒绝。四态在界面上的呈现不同，合并成一个 bool 会丢信息。
- [ ] 7-4 `execute` 每个 IO 步骤之间检查 `token.isCancelled`。长循环里也要检查。
- [ ] 7-5 结果里除了给模型的 `content`，还带 `details`（diff、patch、命中行号），供界面渲染。给模型的文本要短，界面要的细节走 `details`。
- [ ] 7-6 截断在**一处**实现（`AGENTS.md` §1.2）：一个 `truncate(text, limit, note)`，所有工具共用，输出统一带"已截断，原始 N 字符"。

### 7.2 注册表

- [ ] 7-7 `ToolRegistry`：注册、按名查、**按名字典序列出**（§6.6 的前缀稳定要求）。
- [ ] 7-8 支持按会话动态启用/禁用（协议 §10.1）。禁用要落一条 `tools_change` 条目（存储文档 §7.3），这样历史可回放。
- [ ] 7-9 工具集变化会打断缓存前缀（第 2、3 层都变），可以接受，但要在设置界面上提示"切换工具会使本轮重新计费"。

### 7.3 权限门

- [ ] 7-10 `PermissionGate.check(toolName, args) → allow | ask | deny`，在 `execute` **之前**调用（协议 §9）。三态默认值按协议 §9 的表。
- [ ] 7-11 `ask` 弹窗，用户选择可记"本会话内一直允许"。这个记忆是运行时的，不落 entries（它不是对话内容）。
- [ ] 7-12 `deny` 走 7-3 的第四态，模型收到明确的拒绝说明。

### 7.4 各工具（按里程碑排）

- [ ] 7-13 M2 工作区路径基础设施：规范化、`..` 逃逸检测、符号链接、Windows 的 `\\?\` 与保留名（`CON`、`NUL`）、大小写不敏感。**只在这一层实现，各工具不重复写**（`AGENTS.md` §6.1）。
- [ ] 7-14 M2 `list_dir` / `search_files` / `read_file` / `write_file` / `edit_file` / `delete_file`。edit 参考 pi：BOM 剥离、行尾探测（CRLF/LF）与还原、匹配不到就报错**绝不猜**、写入过 mutation 队列串行化。
- [ ] 7-15 M4 `web_search` / `web_fetch`。后端路由（Tavily / Brave / SearXNG / 模型原生）在**一处**选择；搜索配置与聊天模型配置独立（协议 §5）。`web_fetch` 只 GET，不接受模型给的 header / cookie / Authorization。
- [ ] 7-16 M5 `run_js`（见 §8）。
- [ ] 7-17 M6 `save_memory` / `list_memory` / `read_memory`。只有这三个能碰记忆存储，其他工具和 `run_js` 都不能（`AGENTS.md` §6.3）。
- [ ] 7-18 M6 `gen_image` / `edit_image`。命名 `images/日期时间-短ID.png`，编辑产出新文件**绝不覆盖原图**（协议 §4）。

## 8. `runtime/`：`run_js`

- [ ] 8-1 `abstract class WepJsRuntime`，QuickJS 是它的一个实现。所有 JS 执行只经这个抽象（`AGENTS.md` §6.4）。
- [ ] 8-2 **超时必须是真的中断**。`Future.timeout` 只是不再等结果，那个死循环还在烧 CPU（协议明确点出这一点）。正确做法是 `JS_SetInterruptHandler` + 一个被 Dart 侧设置的标志位，让引擎自己在字节码层面停下来。
- [ ] 8-3 内存上限用 `JS_SetMemoryLimit`，栈上限用 `JS_SetMaxStackSize`。
- [ ] 8-4 每次调用**全新 context**，不复用（协议 §6）。
- [ ] 8-5 沙箱里没有：网络、DOM、shell、process、环境变量、真实路径。工作区文件访问只经宿主注入的受限函数，参数在宿主侧再过一遍 §7-13 的路径校验。
- [ ] 8-6 输出上限 16–64 KB，超出走 §7-6 的统一截断。
- [ ] 8-7 QuickJS 要为 Android 四个 ABI 和 Windows x64 各出一份静态库，构建脚本进仓库。这是整个项目里工程量最大的一块，排在 M5 不是偶然。

## 9. `storage/`

完整设计见 `WePChat-Flutter-会话存储设计.md`。这里只列施工项。

- [ ] 9-1 DB isolate：长驻，持唯一写连接，请求经 `SendPort` 串行。UI isolate 不碰 sqlite（`AGENTS.md` §5.3）。
- [ ] 9-2 建表 + `PRAGMA`（WAL / synchronous=NORMAL / foreign_keys=ON）+ `user_version` 迁移框架。降级时明确报错拒绝打开，不兼容读取。
- [ ] 9-3 `entries` 追加：事务内 `head_seq + 1` 取号，同事务更新 `sessions` 的 `updated_at` / `preview` / `context_tokens` / `cost_total`。
- [ ] 9-4 payload 编码三态：`json`（<4 KB）/ `gzip`（≥4 KB，用 `dart:io` 的 `GZipCodec`）/ `external`（≥256 KB，落 blob）。编解码一处实现。
- [ ] 9-5 blob 层：sha256 内容寻址、`blobs` + `blob_refs`、GC（先删表行再删文件）。
- [ ] 9-6 三条查询：`seq >= base_seq` 顺序全取（组装上下文）、尾部 N 条倒序（界面分页）、会话列表只读元信息列。
- [ ] 9-7 `runs` 表 + 启动时扫 `finished_at IS NULL` 标为中断。
- [ ] 9-8 助手消息在 `message_end` 落盘；**工具结果每个执行完立刻落盘**（存储文档 §6.1，理由是副作用已发生）。
- [ ] 9-9 派生状态（模型 / 思考档位 / 工具集）回放实现；与 `sessions` 表缓存列不一致时报错，不静默用缓存（`AGENTS.md` §1.3）。
- [ ] 9-10 truncate 条目支持编辑重发（存储文档 §8）。
- [ ] 9-11 删除会话：软删 → 删 `blob_refs` → 清工作区目录（要确认用户意图，协议里工作区文件是用户产物）→ 硬删行。
- [ ] 9-12 M0 结束时把 `lib/state/session_store.dart` 从内存 mock 切到真存储，**界面不改一行**。这是 M0 的验收标准。

## 10. UI 接线

- [ ] 10-1 `lib/models/` 的展示模型由领域模型派生。`ChatMessage.time` 这种展示字符串在派生时格式化，领域模型里存 epoch ms。
- [ ] 10-2 `isUser` 换成 role 枚举——现在只有 user/assistant，加上 tool_result 后 bool 不够用了。
- [ ] 10-3 界面只订阅 agent 事件（§5-6）。
- [ ] 10-4 设置页接真实配置：provider / key / 模型目录 / 兼容标记 / 搜索后端 / 权限三态 / 记忆开关。key 存平台安全存储还是 DB？**待定，见 §13。**
- [ ] 10-5 用量与费用显示（含 `cacheRead` / `cacheWrite`，§6-12）。
- [ ] 10-6 中断按钮接 `CancellationToken`；"上次被中断，可重试"提示接 §9-7。
- [ ] 10-7 现有的 HTML 预览 / 图片查看 / 文件查看页面接真实工作区文件。

## 11. 里程碑

| 里程碑 | 内容 | 完成标准 |
|---|---|---|
| **M0** | `core/` + `storage/` + DB isolate + 迁移 | 现有界面跑在真存储上，重启后会话仍在，界面代码零改动 |
| **M1** | `ai/` 的 openai-completions + 设置里配 key | 无工具的纯聊天流式跑通，可中断，用量正确显示 |
| **M2** | loop + 工具注册 + 权限门 + 工作区文件工具 | 能让模型读写工作区文件，权限三态生效，写操作串行 |
| **M3** | anthropic-messages + openai-responses + 缓存策略 + 压缩 | 三种 API 都能跑；界面能看到 cacheRead > 0；长会话自动压缩不报错 |
| **M4** | `web_search` / `web_fetch` + 搜索后端 | 至少两个后端可切换 |
| **M5** | QuickJS + `run_js` | 死循环脚本能被真中断（不是超时放手） |
| **M6** | 记忆 + `gen_image` / `edit_image` | 记忆三态开关生效；图片不覆盖 |
| **P1** | 协议 §11 的 P1 项 | — |

顺序理由：存储在最前面，因为它是唯一"错了要迁移数据"的部分——晚改代价最大。缓存策略排在 M3 而不是 M1，因为它需要三个适配器都在场才能验证抽象是否正确；但 §6.2 的确定性序列化从 M1 第一天就要守，那是习惯问题不是功能。

## 12. 每个里程碑的检查

代理能跑的只有两条（`AGENTS.md` §9）：

- [ ] 12-1 `dart format --set-exit-if-changed .`
- [ ] 12-2 `flutter analyze`

需要用户在真机 / 真环境跑的（代理不得声称已通过，只能标"未执行"）：

- [ ] 12-3 `flutter test`（含 §6-8 的字节稳定性测试、§6-13 的幂等测试、归约器纯函数测试、schema 校验器测试）
- [ ] 12-4 Android 真机：四个 ABI 装得上、SQLite native 库能加载、大文件读不卡 UI
- [ ] 12-5 Windows Release 打包：sqlite3.dll 打进产物
- [ ] 12-6 真实 API 联通：三家各一个模型，看 `cacheRead` 是否 > 0（缓存策略唯一的验证手段）
- [ ] 12-7 杀进程恢复：生成中途杀掉，重启后工具结果在、中断提示出现
- [ ] 12-8 断网 / 401 / 429 / 超时四种失败路径的界面表现

## 13. 待定决策

需要用户拍的，按重要性排：

1. **偏离 A**：记忆从 `memory.json` 迁到 SQLite 表（存储文档 §12）。接受则同步改协议 §2.2。
2. **偏离 B**：事件补 `message_start` / `message_end`（本文 §5-5）。接受则同步改协议 §10.3。
3. **偏离 C**：五个模块做成目录分层而非 pub 包（本文 §0.3）。
4. **API key 存哪**：平台安全存储（Android Keystore / Windows DPAPI，需要新依赖或自写平台通道）还是 DB 里明文。DB 明文的实际风险在 Android 上很低（应用私有目录，未 root 拿不到），Windows 上则等于明文可读。倾向"Windows 用 DPAPI，Android 用私有目录明文"，但这需要写平台通道，工作量不小。
5. **不做自动恢复**只做中断提示（存储文档 §6.2）。
6. **编辑重发用 truncate 标记**而非分支树（存储文档 §8）。
7. **搜索后端**第一版做哪两个。Tavily 要 key，SearXNG 要公共实例（可用性不稳），Brave 有免费额度。
8. **压缩触发**是自动还是询问。协议没说。自动更省心，但会在用户没预期时产生一次昂贵请求。

上面 1–3 是文档一致性问题，不定就会让代码和协议长期不一致，建议先定这三个。

