# WePChat Flutter — M2 及后续交接文档

写给下一个会话。**M0 与 M1 已完成并由用户实测通过**；本文说明当前代码的真实形状、
已经踩过的坑、以及 M2 该从哪里下手。

**验证基线**（2026-09-02）：`flutter analyze` 无问题，`flutter test` **329/329 通过**。
用户已在真实环境实测**三种协议的无工具纯聊天 + 中断**，均正常。

**最新进展**（2026-09-02，会话末尾）：用户的五项界面完善请求已全部完成：
1. Markdown 渲染（链接、图片、数学公式）
2. 工作区面板集成真实文件列表与"打开目录"功能
3. 设置页滚动时的 AXTree 错误修复
4. 聊天区打磨（文本选择、每条消息的用量统计、复制/重新生成/编辑按钮）
5. 初始状态与布局（新会话自动选择默认模型、工作区面板默认折叠、设置按钮移至左侧边栏底部）

**下一会话的起点**：M2 工具开发（搜索工具 + 长期记忆）。纯聊天与界面已完整。

---

## 1. 必读设计文档

设计文档都在 `docs/`，`AGENTS.md` 在仓库根。按这个顺序读：

1. `WePChat-Flutter-实施TODO.md` — 施工清单，章节号（§5-1 这种）在代码注释里被大量引用
2. `WePChat-Flutter-会话存储设计.md` — 存储层完整设计
3. `WePChat-Flutter-功能与工具协议.md` — 工具与功能契约

代码注释里写 `（§5-8）` 指的是实施 TODO 的章节。改代码时如果和注释里的理由冲突，
先回去读那一节，不要直接改注释。

实施 TODO 的 §0（"当前代码状态"）写于开工前，描述的是那时的 55 个文件 / 零依赖状态，
**已经不是现状**，别拿它当现状读。

---

## 2. 用户定的工作方式（比技术细节更重要）

- **这是一个轻量日常聊天项目。** 功能能用优先于形式完备。用户明确说过"我做的规划有点
  太严密了，导致推进太慢"，文档里的"工程洁癖"该删就删。
- **顺序是用户定的**：三个协议适配器 → 设置页配置 → **用户自己测无工具纯聊天** →
  测试无误后再接 loop / 工具注册 / 权限 / tools。前三步已完成，现在在第四步的门口。
- **需要真实窗口的测试交给用户跑**，代理只保留 headless 单元测试。用户原话：
  "有复杂的测试让我来呗，我打开窗口操作两下再复制报错给你不是挺快的"。
  交接时给**确切命令**和**要看什么**。属于这一类：流式渲染、工具卡片、权限弹窗、
  滚动与焦点。
- **API key 的处置是硬约束**：存 `settings.json`，界面**永不显示明文**（只显示
  `ProviderConfig.maskedKey`，前 6 + 后 4），日志与输出一律过 `redact()`。

---

## 3. 目录结构

```
lib/
  core/         取消令牌、错误类型、ULID、日志脱敏
  storage/      DB isolate、迁移、DAO、blob、payload 编码
  platform/     应用数据目录、工作区目录、settings.json 读写
  ai/           三个适配器 + SSE + 请求构造 + 累积器 + 模型目录 + 兼容标记
  tools/        Tool 抽象、注册表、EchoTool
  agent/        AgentLoop、AgentEvent（写好了，纯聊天路径**没走它**）
  state/        SessionStore、AppSettings、chat_turn（ai↔storage 类型映射）
  models/       展示模型 + markdown_blocks（块级 Markdown 解析）
  ui/           界面
  app/          bootstrap、shell、导航
```

---

## 4. 关键不变量（改代码前必须知道）

**存储是 append-only。** `entries` 表的行永不修改。理由不是洁癖，是 prompt cache：
改一条旧消息会让它之后所有请求的缓存前缀失效。压缩也不删行，只推进 `base_seq`。

**DB isolate 持唯一写连接。** UI isolate 永不碰 sqlite。所有请求经 `SendPort` 串行。

**`storage_isolate.dart` 的关闭顺序很脆弱。** `close()` 用的是**不带 `_closed` 守卫**的
私有 `_send<T>()`，因为 `close()` 自己先把 `_closed` 设成了 true。如果让它走带守卫的
`send<T>()`，`ShutdownRequest` 会被守卫拒掉、异常被 catch 吞掉、isolate 被直接 kill，
SQLite 句柄不释放——Windows 上表现为测试 tearDown 删目录时 `errno = 32`
（文件被占用），15 个存储测试全红。别把这两个方法合并。

**取消是协作式的。** Dart Future 不可取消，所以长操作接 `CancellationToken`，
自己轮询 `isCancelled` 或调 `throwIfCancelled()`。`CancellationTokenSource.derive()`
做级联取消。HTTP 层靠 `client.close()` 真断连接。

**适配器永不抛异常。** 失败编码进 `StreamDone` 的 `stopReason`（`error` / `aborted`）
加 `errorMessage`。上层只有一条失败路径要处理。

**`ApiKind` 挂在 provider 上，不挂在模型上。** 端点决定协议。`ModelSpec` 上**没有**
`apiKind` 字段——旧文档写过，是错的，别照着加。

**模型是用户数据。** 权威在 `settings.json`，`kSeedProviders` / `kSeedModels` 只在
对应 JSON 键**缺失**时作为首启种子。用户删掉的模型不会因为重启回来。

**两套同名类型。** `lib/ai/messages.dart` 的 `StopReason` / `TokenUsage`（非空 int、
有 `reasoningTokens`、有 `operator +`）与 `lib/storage/models.dart` 的同名类型
（可空 int、有 `cost`、有 `.wire`）**不是一回事**。映射集中在
`lib/state/chat_turn.dart`；`session_store.dart` 用 `import '../ai/messages.dart' as ai;`
消歧。同时 import 两边而不加别名一定编不过。

---

## 5. 已完成：M1

### 5.1 三个适配器

| 文件 | 协议 | 测试 |
|---|---|---|
| `ai/anthropic/anthropic_api.dart` | anthropic-messages | `test/ai/anthropic_stream_test.dart` + `anthropic_request_test.dart`（含字节稳定性 golden） |
| `ai/openai/openai_completions_api.dart` | openai-completions | `test/ai/openai_completions_stream_test.dart` |
| `ai/openai/openai_responses_api.dart` | openai-responses | **还没有测试**——见 §7 |

共用件：`ai/sse.dart`（SSE 解析，19 条测试）、`ai/http_transport.dart`（重试 + 退避 +
取消接线 + 错误响应转领域错误 + 只记 method/host/path/status/耗时 的日志）。

三个适配器都接 `StreamPoster` typedef 而不是直接调 `postStreaming`，所以测试可以塞
一段录好的 SSE，不必起 HTTP server、不必联网。照着现有测试的 `apiWith(sse)` 写。

差异**全部**表达在 `ModelSpec.compat`（九个标记），**没有一处按厂商 if 分支**。
新增标记必须说明"哪个真实模型需要它"。

### 5.2 设置页

`ui/settings/` 下：

- `provider_dialog.dart` — 只填四项：名称、API 类别、baseUrl、Key。编辑时 Key 留空 = 不修改。
- `models_dialog.dart` — `/models` 拉取后**勾选**添加（中转站会返回几百个 id，全加进去
  聊天顶栏会变成电话簿）、手动添加、逐个「发一句 hi」探活。
- `model_meta_dialog.dart` — 逐模型改显示名 / 上下文窗口 / 最大输出 / 九个兼容标记，
  高级项默认折叠。

`ai/model_discovery.dart` 提供 `fetchModelIds(config)` 与 `probeModel(model:, config:)`。

**上下文窗口是每个模型自己的**（`ModelSpec.contextWindow`），全局设置项已删除，别加回来。

### 5.3 纯聊天链路

`SessionStore.sendMessage` 现在真的会发请求。链路：

```
用户消息落库（先落，再考虑能不能发——输入框那边已经清空了）
  → 首条消息顺带改标题
  → 解析 ModelSpec / ProviderConfig
  → createProviderApi(model:, config:)
  → readContext() 过滤 isUsableInContext → List<ChatMessageModel>
  → startRun()
  → api.stream(...) 边收边 _paintStreaming()
  → _persistAssistant() 一次写入
  → finishRun(outcome) → _reload()
```

**故意不走 `AgentLoop`。** 纯聊天只需要适配器，先把这条链路验通；工具、权限、循环
是 M2 的事。接工具时这里要改成走 loop，见 §6。

失败分两类，处置不同：

- **配置类**（没配 key / 模型被删 / provider 没了）→ 不落库，只发一次性 `_notice`，
  界面读走显示成 toast。理由：这不是对话内容，写进历史会永远留在记录里，用户改完
  设置也擦不掉。
- **请求类**（网络、API 报错）→ 落一条 assistant 条目，`stopReason: error`，
  错误文本进 `payload['error']`，界面渲染成 ⚠️ 引用块。它被
  `EntryRecord.isUsableInContext` 挡在下次请求之外，所以看得见但不会污染上下文。
- **中断**：有文字 → `aborted` 落库；一个字都没有 → 什么也不落，当这轮没发生过。

其它已做的细节：

- `isGenerating` 看的是**当前会话**（`_run?.sessionId == _activeId`），不是"有没有任务"。
  生成中切到别的会话，那边输入框应该是正常的。`isGeneratingIn(id)` 给会话列表用。
- 全局同时只允许一个 run。这是刻意简化，日常聊天不需要并发。
- `temperature` 按 `compat.supportsTemperature` 决定发不发（o 系列拒收这个字段）。
- 助手消息经 `models/markdown_blocks.dart` 的 `parseMarkdownBlocks` 解析成块：
  标题 / 围栏代码 / 列表 / 引用 / 管道表格 / 段落。**未闭合的围栏当作已闭合**——
  流式时最后一块必然未闭合，显示成字面 ``` 会让人以为坏了。用户消息**不解析**
  （用户打的 `-` 开头是破折号，不是列表）。
- thinking 渲染成 💭 引用块，但**不回传**给模型。
- 聊天区滚动：生成中用 `jumpTo` 不用动画（240ms 动画走不完下一个 delta 就来了），
  且只在用户本来就贴着底部（距底 < 120px）时才跟，往上翻看历史不会被拽回去。

---

## 6. M2 待办：工具注册 + 权限门 + 文件工具

**当前状态**（2026-09-02）：工具注册表、`PermissionGate`、`AgentLoop` 均已完成。
**读类工具已完成并测试通过**（`list_files`、`read_file`、`search_files`，见 
`test/tools/workspace/read_tools_test.dart`，84 个测试用例覆盖正常路径、参数容错、
越界保护、取消）。工作区扫描（`workspace_scanner.dart`）已集成到 `SessionStore`。

**下一步**：写类工具（`write_file`、`edit_file`、`delete_file`）+ 把纯聊天链路换成 loop。

### 6.1 第一件事：路径安全层（§7-13）

**M2 的第一件事，不是文件工具本身。** 规范化、`..` 逃逸检测、符号链接、
Windows 的 `\\?\` 前缀与保留名（`CON` / `NUL`）、大小写不敏感。
**只在这一层实现，各工具不重复写。** 任何文件工具拿到模型给的路径后都必须先过它。

`WorkspacePaths`（M0 就有）能展开 `~` 并建 `<root>/<session_id>/`，是地基，但它
**不做安全校验**。

**已完成**：`WorkspaceGuard`（`lib/platform/workspace_guard.dart`）提供 `resolve(path)` 
和 `resolveForWrite(path)`，处理所有路径安全检查。读类工具已经在用它。

### 6.2 第二件事：把纯聊天链路换成 loop

`SessionStore._streamReply` 现在直接消费 `api.stream(...)`。接工具时改成
`AgentLoop.run(history, token)` 消费 `AgentEvent`。已经写好且有测试的部分：

`AgentLoop.run(history, token)` 返回 `Stream<AgentEvent>`，**不抛异常**，失败编码进
`AgentDone`。四条硬规则，都有理由，别顺手改：

- **每个 `tool_use` 必须配一个 `tool_result`**，取消时也不例外。缺一个下次请求会被 API 拒。
  所以执行工具的循环里没有 `break`。
- **`stopReason == length` 且有工具调用时整批不执行**。参数被输出上限截断了。
- **`error` / `aborted` 的轮次不进下一次请求的历史**（`isUsableInHistory`）。
- **适配器没产生 `StreamDone` 就当错误收场**，不继续循环。

`AgentEvent`：`AgentTurnStart` / `AgentMessageUpdate` / `AgentMessageEnd` /
`AgentToolStart` / `AgentToolEnd` / `AgentDone`。start/update/end 三分是对协议 §10.3
的**有意偏离**（偏离 B）——界面要知道"这条完了"才能收光标、落库、显示用量。

`AgentDone.hitMaxIterations` 区分"撞上迭代上限"和"模型自然说完"。

**落盘时机**（存储设计 §6.1、§9-8）：助手消息在 `message_end` 落盘（现在就是这样）；
**工具结果每个执行完立刻落盘**——副作用已经发生了，进程被杀也不能丢。这半条还没做。

### 6.3 工具层现状

```dart
abstract class WepTool {
  String get name;        // list_files
  String get label;       // 列出文件
  String get description; // 进 prompt，影响缓存前缀
  Map<String, Object?> get schema;
  ToolExecutionMode get mode;  // readonly | sequential
  
  Map<String, Object?> prepareArguments(Map<String, Object?> raw);
  Future<ToolResult> execute(Map<String, Object?> args, ToolContext ctx);
}
```

`ToolResult` 四态：`ok` / `failed` / `cancelled` / `permissionDenied`（`lib/tools/tool.dart`）。
`content` 给模型，`details` 给界面。

`ToolRegistry.definitions` 按名字**字典序**排序（影响缓存前缀），且**只在这里排**。
`test/tools/tool_registry_test.dart` 有一条测试专门守这个。

**已完成的读类工具**：
- `ListFilesTool` — 递归列出工作区文件，相对路径，支持 `recursive` 和 `path` 参数
- `ReadFileTool` — 读文件内容，带行号，支持 `lines` 区间，BOM 自动剥离，拒绝二进制
- `SearchFilesTool` — 全文搜索，支持正则、glob 过滤、max_matches 限制

测试覆盖：84 个用例，包含正常路径、参数容错、越界保护、取消、同一目录顺序一致性、
二进制跳过、符号链接过滤。

### 6.4 写类工具的约束

- **`write_file` 不截断已存在的文件**：先检查 `File.existsSync()`，存在则报错让模型选
  `edit_file`。不静默覆盖——文件可能是之前工具写的，模型忘了。
- **`edit_file` 的 `find` 必须逐字匹配**，找不到就报错（pi 的做法，实施 TODO §6.5）。
  不能猜"可能是这一段"——改错行比拒绝改更糟。
- **BOM 剥离、行尾还原**：读入时去 BOM、记住原文是 CRLF 还是 LF，写回时还原。
  Windows 文件很多是 CRLF，改一次全变 LF 会让 git diff 爆炸。
- **Mutation 队列串行化**：所有写操作（write / edit / delete）进 `MutationQueue`，
  一个一个来——并发写同一文件是未定义行为，串行是**工具的责任**，不能推给模型判断。

### 6.5 权限门（§7-10 ~ §7-12）

`PermissionGate.check(toolName, args) → allow | ask | deny`，在 `execute` **之前**调。
三态默认值按协议 §9 的表。`ask` 弹窗，用户可选"本会话内一直允许"——这个记忆是运行时的，
**不落 entries**（它不是对话内容）。`deny` 也要产生一条 tool result 告诉模型"用户拒绝了"，
不能静默跳过，否则模型会重试到死。

**已完成**：`PermissionGate` 在 `lib/tools/permission_gate.dart`，提供 `check` 方法和
会话内记忆。`ToolRegistry.dispatch` 在调用工具前先过权限门。

---

## 7. 下一会话的起点：搜索工具 + 长期记忆

M2 的剩余工作分两部分：

### 7.1 搜索工具（实施 TODO §7-15，M4）

**`web_search` / `web_fetch`**。后端路由（Tavily / Brave / SearXNG / 模型原生）在**一处**选择；
搜索配置与聊天模型配置独立（协议 §5）。`web_fetch` 只 GET，不接受模型给的 header / cookie / Authorization。

**待定事项**：
- Tavily API key 怎么配、配在哪一屏（§9，"待用户拍的决策"）
- 是否需要多个搜索后端（实施 TODO §13 已定：第一版只做 Tavily，等有人真的要换再加第二个）

### 7.2 长期记忆（实施 TODO §7-17，M6）

**`save_memory` / `list_memory` / `read_memory`**。只有这三个能碰记忆存储，其他工具和 `run_js` 都不能
（AGENTS.md §6.3）。

记忆存储方案（实施 TODO §13，偏离 A）：**SQLite 表而非 `memory.json`**（存储文档 §12）。
M6 落地时同步改协议 §2.2。

表结构待设计：至少需要 `id` / `session_id` / `content` / `created_at` / `tags`。
支持全文搜索（FTS5）以便 `list_memory` 按关键词过滤。

---

## 8. 明确的欠账清单

按"现在就该补"到"可以再等等"排：

1. **openai-responses 没有流式测试。** 另两个协议都有。照
   `test/ai/openai_completions_stream_test.dart` 的形状写：`apiWith(sse)` 塞录好的
   事件流，覆盖正文 / 思考 / 工具调用分片 / usage / 错误 / 取消。用户已实测这个协议
   能聊天，但分片和工具调用路径没有回归保护。
2. ~~**用量显示没做**~~。**已完成**（2026-09-02）：`MessageActionBar` 显示输入/输出/缓存读写/
   思考 token 与耗时，悬停显示，触摸端常驻。
3. **"上次被中断，可重试"提示没做**（§10-6、§9-7）。
   `AppBootstrap.interruptedSessionIds` 已经取到了，但没人读它。
4. **`ChatMessage.isUser` 还是 bool**（§10-2）。加 tool_result 后不够用，M2 接工具时
   一起换成 role 枚举，越晚改牵连越多。
5. **`ChatMessage.time` 还是格式化好的字符串**（§10-1）。领域模型该存 epoch ms。
6. ~~**`EntryType.truncate` 只有枚举值**~~。**已完成**（2026-09-02）：`SessionStore.regenerate` 
   和 `editUserMessage` 调用 `storage.truncateFrom`，`ChatView` 有完整的编辑重发与重新生成界面。
7. **删除会话不清工作区目录**（§9-11）。删除弹窗明写"工作区文件不受影响"，是刻意的，
   但要不要给一个"连同文件一起删"的选项没定。
8. **`sqlite3_flutter_libs` 从没在真机验过**（§2-2、§12-4、§12-5）：Android 四个 ABI、
   Windows Release 打包 `sqlite3.dll` 进产物。M0 加进来时没验，一直欠着。

---

## 8. 测试

### 分布

| 文件 | 覆盖 |
|---|---|
| `test/core/` | 取消令牌、ULID、日志脱敏 |
| `test/storage/wep_storage_test.dart` | 生命周期 / 条目 / 编码 / 派生状态 / run / GC / 压缩 |
| `test/storage/migration_test.dart` | 建库 / v1→v2 / 回滚 / 拒绝降级 |
| `test/platform/workspace_paths_test.dart` | `~` 展开、会话子目录 |
| `test/ai/sse_test.dart` | SSE 解析 |
| `test/ai/anthropic_request_test.dart` | 含字节稳定性 golden |
| `test/ai/anthropic_stream_test.dart` | anthropic 流式事件 |
| `test/ai/openai_completions_stream_test.dart` | completions 流式 / 思考 / 工具分片 / usage / 失败 / 取消 |
| `test/tools/tool_registry_test.dart` | 注册表与字典序 |
| `test/agent/agent_loop_test.dart` | 循环终止条件、工具配对、用量累计、历史过滤 |
| `test/models/markdown_blocks_test.dart` | 块级 Markdown 解析 |
| `test/app_settings_test.dart` | provider / 模型 / 默认模型 / 图片模型的增删改与持久化 |
| `test/session_store_test.dart` | 状态机不变量 |
| `test/integration/session_store_integration_test.dart` | 跑真存储、跨实例持久化 |
| `test/widget_test.dart` | 窄屏 / 宽屏 / 收起侧栏 |

### 两个 store 测试为什么不会真的发请求

它们用 `AppSettings.memory()`，种子 provider 的 key 都是空串，所以每次
`sendMessage` 都停在 `createProviderApi` 抛的 `AuthError` 上，走 notice 分支，
只留下用户那一条消息。想测真实流式生成要塞假适配器——那是适配器测试在做的事。

### 必须知道的测试陷阱

**`testWidgets` 的 fake-async 区不能 await 真实 IO。** `testWidgets` 在 fake-async
zone 里跑 body。在这个 zone **内部创建**的、由真实 IO 支撑的 future
（`Directory.create`、`storage.close()`、isolate `SendPort` 往返）永远不会完成，
而且**之后任何 `tester.runAsync` 都救不回来**——zone 绑定发生在创建时，不是 await 时。

我为此改错三次，全都对着 dispose 顺序下手。真正的修法在创建侧：
storage 在 fake-async zone 外面建，工作区目录创建改成同步的 `createSync`。

写 widget 测试时：IO 相关的东西经 `runAsync`（或在 zone 外）创建；widget 测试会碰到
的代码路径优先用同步文件调用。

**PowerShell 的 `Select-Object -Last N` 会缓冲到进程结束。** 想看长测试的实时进度就
直接重定向到文件，别管道。

**别用 Write 工具"追加"内容。** Write 是整文件覆盖。我在这个会话里用它往
`session_store.dart` 末尾加一个类，结果把整个文件冲成了 8 行，只能凭上下文重建。
要追加就用 Edit。

---

## 9. 待用户拍的决策（实施 TODO §13）

已定的八条见实施 TODO §13，不重复。仍然悬着的：

- 搜索后端第一版做 Tavily（已定），但 key 怎么配、配在哪一屏没设计。
- 删除会话要不要连带删工作区文件（见 §7 第 7 条）。
- 压缩自动触发（已定），但"上下文已压缩"的界面提示长什么样没设计。

---

## 10. 检查命令

代理能跑的：

```
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

需要用户在真机 / 真环境跑的（代理不得声称已通过）：Android 四 ABI 装载、
Windows Release 打包（`sqlite3.dll` 要进产物）、真实 API 联通看 `cacheRead > 0`（M3）、
杀进程恢复、断网 / 401 两条失败路径的界面表现（429 / 超时走同一条错误通道，
`http_transport.dart` 的 `_toError`，不单独构造）。
