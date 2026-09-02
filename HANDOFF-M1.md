# WePChat Flutter — M1 及后续交接文档

写给下一个会话。M0 已完成并验证；本文说明当前代码的真实形状、已经踩过的坑、
以及 M1 该从哪里下手。

**验证基线**（2026-09-01）：`flutter analyze` 无问题，`flutter test` 164/164 通过。

---

## 1. 三个必读设计文档

按这个顺序读：

1. `WePChat-Flutter-实施TODO.md` — 施工清单，章节号（§5-1 这种）在代码注释里被大量引用
2. `WePChat-Flutter-会话存储设计.md` — 存储层完整设计
3. `WePChat-Flutter-功能与工具协议.md` — 工具与功能契约
4. `M0-完成状态.md` — M0 做了什么、剩下什么

代码注释里写 `（§5-8）` 指的是实施 TODO 的章节。改代码时如果和注释里的理由冲突，
先回去读那一节，不要直接改注释。

---

## 2. 已完成：M0（存储 + core）

### 目录结构

```
lib/
  core/         取消令牌、错误类型、ULID、日志脱敏
  storage/      DB isolate、迁移、DAO、blob、payload 编码
  platform/     应用数据目录、工作区目录
  ai/           适配器契约 + Anthropic 实现 + SSE 解析
  tools/        Tool 抽象、注册表、EchoTool
  agent/        AgentLoop、AgentEvent
  state/        SessionStore、AppSettings（ChangeNotifier）
  models/       展示模型（ChatSession / ChatMessage / ...）
  ui/           界面（M0 期间零改动）
  app/          bootstrap、shell、导航
```

### 关键不变量（改代码前必须知道）

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
做级联取消。


---

## 3. 已完成：M1 的一部分

M1 的表格定义是"无工具的纯聊天流式跑通，可中断，用量正确显示"。适配器层和 agent 层
的**代码**已经写好且有测试，但**没接到界面上**。

### `lib/ai/` — 适配器契约

```dart
abstract class ProviderApi {
  Stream<StreamEvent> stream(ProviderRequest request, CancellationToken token);
  Future<ChatMessageModel> streamSimple(...);   // 实现假适配器时别忘了这个
}
```

注意 `ProviderApi` **没有** `providerId` 成员。写测试替身时加 `@override String get providerId`
会得到 "The getter doesn't override an inherited getter" 警告。

`ModelSpec` 的必填参数：`id` / `displayName` / `providerId` / `apiKind` / `contextWindow` /
`maxOutputTokens`。`apiKind` 是 `ApiKind` 枚举（`anthropicMessages` / `openaiCompletions` /
`openaiResponses`），容易漏。

`StreamEvent` 是 sealed 的：`StreamStart` / `StreamTextDelta` / `StreamThinkingDelta` /
`StreamToolCallDelta` / `StreamDone`。**每个事件都带完整的 partial 消息**，界面整条重绘，
不要自己累加 delta。

**适配器不抛异常。** 失败编码进 `StreamDone` 的 `stopReason`（`error` / `aborted`）。
这条约定 agent loop 依赖，别在适配器里往外抛。

已实现：Anthropic（`lib/ai/anthropic/`）。M1 表格要求的是 **openai-completions**，
还没写——这是 M1 最大的一块待办。

### `lib/tools/` — 工具层

```dart
abstract class Tool {
  ToolDefinition get definition;
  String get name => definition.name;
  bool get requiresApproval => false;   // 读类 false，写/执行类 true
  Future<ToolResult> execute(Map<String, Object?> arguments, ToolContext context);
}
```

`ToolDefinition` 是面向模型的声明（进请求体，影响缓存）；`Tool` 是面向程序的实现。
`requiresApproval` 放在工具自己身上而不是外部 if 分支上，是为了让"忘了判断"的默认
结果是**拒绝**而不是放行。

`ToolRegistry.declarations` 按名字**字典序**排序，且**只在这里排**。适配器不要再排一次——
两处排序会让缓存在其中一处改了之后静默失效。`test/tools/tool_registry_test.dart`
有一条测试专门守这个：两个注册顺序不同的注册表必须产出相同的声明序列。

`dispatch()` 永不抛：未知工具名 → `ToolResult.error` 且**文案里列出可用工具名**（模型要靠
这个自我纠正）；工具内部抛异常 → 收成 error；token 已取消 → 返回中断结果且不执行。

### `lib/agent/` — 主循环

`AgentLoop.run(history, token)` 返回 `Stream<AgentEvent>`，**不抛异常**，失败编码进
`AgentDone`。循环结构：发请求 → 收流 → 若 `stopReason == toolUse` 则执行全部工具、
结果拼成一条 tool 消息进历史、回到第一步；否则结束。

四条硬规则，都有理由，别顺手改：

- **每个 `tool_use` 必须配一个 `tool_result`**，取消时也不例外。缺一个下次请求会被 API 拒。
  所以执行工具的循环里没有 `break`。
- **`stopReason == length` 且有工具调用时整批不执行**。参数被输出上限截断了，执行等于
  拿错参数干活。
- **`stopReason` 为 `error` / `aborted` 的轮次不进下一次请求的历史**（靠 `isUsableInHistory`
  过滤）。留着会让模型看到半句话，或看到一个没有结果的 `tool_use`。
- **适配器没产生 `StreamDone` 就当错误收场**，不继续循环。继续会拿 null 当历史发请求。

`AgentEvent`：`AgentTurnStart` / `AgentMessageUpdate` / `AgentMessageEnd` /
`AgentToolStart` / `AgentToolEnd` / `AgentDone`。start/update/end 三分是对协议 §10.3
（只有 `message_update`）的**有意偏离**——界面需要知道"这条完了"才能收光标、落库、
显示用量，靠 update 自己猜等于把状态机搬进界面。

`AgentDone.hitMaxIterations` 区分"撞上迭代上限"和"模型自然说完"，界面要能区分：
前者意味着任务可能没做完。

---

## 4. M1 待办：把 agent 接到界面

这是下一个会话的主线。

### 4.1 当前 `SessionStore` 的形状

`lib/state/session_store.dart` 是 `ChangeNotifier`，已经跑在真存储上。相关成员：

- `bool get isGenerating => false;` — 硬编码 false，注释写着 M0 暂无生成状态
- `Future<void> sendMessage(String text)` — 只落一条用户消息，注释明确写着
  "M0 到此为止——没有 agent，就不伪造回复"
- `void stopGenerating() {}` — 空实现，注释写着 M1 接 `CancellationToken`
- `Future<void> _reload(String sessionId)` — 从存储重读一个会话替换列表项

三个点就是接线位置。

### 4.2 接线要做的事

1. **`sendMessage` 落用户消息后启动 `AgentLoop`**，订阅事件流。
   `AgentMessageUpdate` 更新内存里的 partial 消息并 `notifyListeners()`；
   `AgentMessageEnd` 落盘。
2. **落盘时机**（存储设计 §6.1，实施 TODO §9-8）：助手消息在 `message_end` 落盘；
   **工具结果每个执行完立刻落盘**——副作用已经发生了，进程被杀也不能丢。
3. **`isGenerating` 改成真状态**，`stopGenerating()` 持 `CancellationTokenSource`
   并 `cancel()`。
4. **`runs` 表**：开始时 `startRun`，结束时 `finishRun`。启动时的
   `reconcileInterruptedRuns()` 已经在 bootstrap 里跑了，界面要把"上次被中断，
   可重试"提示显示出来（实施 TODO §10-6）。
5. **用量显示**（§10-5）：`AgentDone.usage` 是整轮累计，含 `cacheRead` / `cacheWrite`。

### 4.3 展示模型的两处欠账

- `ChatMessage.isUser` 是 `bool`（`lib/models/chat.dart:53`）。加上 tool_result 之后
  bool 不够用了，实施 TODO §10-2 要求换成 role 枚举。趁接线一起改，越晚改牵连越多。
- `ChatMessage.time` 是格式化好的字符串。领域模型里存 epoch ms，格式化只在派生时做
  （§10-1）。

### 4.4 还缺的适配器

M1 表格点名 **openai-completions**。`lib/ai/` 目前只有 Anthropic。写的时候：

- 请求体字段顺序显式固定（§6.2 确定性序列化）。这是习惯问题，M1 第一天就要守，
  不要等 M3 缓存策略再补。
- 工具声明**不要再排序**，`ToolRegistry` 已经排过了。
- 失败编码进 `StreamDone`，不抛。
- 参考 `test/ai/anthropic_request_test.dart` 里的字节稳定性 golden 测试，
  新适配器也配一条。

---

## 5. M2 及以后

`WorkspacePaths`（M0 新增）已经能展开 `~` 并建 `<root>/<session_id>/`，这是 M2
文件工具的地基。但**§7-13 的路径安全层还没写**，那是 M2 的第一件事：

规范化、`..` 逃逸检测、符号链接、Windows 的 `\\?\` 前缀与保留名（`CON` / `NUL`）、
大小写不敏感。**只在这一层实现，各工具不重复写**。任何文件工具在拿到模型给的路径后
都必须先过这一层。

M2 的 `edit_file` 参考 pi 的做法：BOM 剥离、行尾探测（CRLF/LF）与还原、
**匹配不到就报错绝不猜**、写入过 mutation 队列串行化。

后续里程碑见实施 TODO §11 的表格。

---

## 6. 测试

### 现状

164 个测试全过。分布：

| 文件 | 覆盖 |
|---|---|
| `test/core/` | 取消令牌、ULID、日志脱敏 |
| `test/storage/wep_storage_test.dart` | 27 条：生命周期 / 条目 / 编码 / 派生状态 / run / GC / 压缩 |
| `test/storage/migration_test.dart` | 8 条：建库 / v1→v2 / 回滚 / 拒绝降级 |
| `test/platform/workspace_paths_test.dart` | 4 条：`~` 展开、会话子目录 |
| `test/ai/sse_test.dart` | 19 条 SSE 解析 |
| `test/ai/anthropic_request_test.dart` | 16 条，含字节稳定性 golden |
| `test/ai/anthropic_stream_test.dart` | 流式事件 |
| `test/tools/tool_registry_test.dart` | 12 条 |
| `test/agent/agent_loop_test.dart` | 循环终止条件、工具配对、用量累计、历史过滤 |
| `test/integration/` | SessionStore 跑真存储 |
| `test/widget_test.dart` | 3 条：窄屏 / 宽屏 / 收起侧栏 |

### 分工约定（用户明确要求）

**需要真实窗口的测试交给用户跑**，代理只保留 headless 单元测试。用户的原话：
"有复杂的测试让我来呗，我打开窗口操作两下再复制报错给你不是挺快的"。

交接时给出**确切命令**和**要看什么**。属于这一类的：流式回复渲染、工具调用卡片、
权限确认弹窗、滚动与焦点行为。

这条约定的来由：我在一个 `testWidgets` 的 fake-async 挂起上连续猜错三次、烧掉约
25 分钟，而真实窗口能立刻看出问题。

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

---

## 7. 待用户拍的决策（实施 TODO §13）

前三条是文档一致性问题，不定就会让代码和协议长期不一致。**代码已经按偏离后的方案写了**，
文档还没同步：

1. **偏离 A**：记忆从 `memory.json` 迁到 SQLite 表（`UNIQUE(category, key)`）。
   接受则同步改协议 §2.2。
2. **偏离 B**：事件补 `message_start` / `message_end`。接受则同步改协议 §10.3。
   **代码已按此实现**（见 §3 的 `AgentEvent`）。
3. **偏离 C**：五个模块做成目录分层而非 pub 包。**代码已按此实现**。

其余待定：API key 存哪（§13.4，倾向 Windows DPAPI + Android 私有目录明文，
但要写平台通道）；不做自动恢复只做中断提示；编辑重发用 truncate 标记；
搜索后端第一版做哪两个；压缩触发是自动还是询问。

---

## 8. 检查命令

代理能跑的：

```
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

需要用户在真机 / 真环境跑的（代理不得声称已通过）：Android 四 ABI 装载、
Windows Release 打包（`sqlite3.dll` 要进产物）、真实 API 联通看 `cacheRead > 0`、
杀进程恢复、断网 / 401 / 429 / 超时四种失败路径的界面表现。
