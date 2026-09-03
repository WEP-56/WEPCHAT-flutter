# WePChat Flutter 接手文档

更新：2026-09-03

这份文档只记录当前接手所需的信息。已经完成的适配器、工具链、聊天主流程和界面基础能力不在这里重复展开；改动前先读根目录 `AGENTS.md`，并遵守“先搜索、局部修改、明确失败、不要静默 fallback”的约束。

## 当前起点

项目面向 Android 和 Windows，业务逻辑优先放在纯 Dart 层，平台差异集中在 `lib/platform/`。

主要目录：

```text
lib/ai/          三种模型协议、SSE、请求与流式累积
lib/agent/       AgentLoop 与 AgentEvent
lib/tools/       工具契约、注册表、权限门、工作区/搜索/图片工具
lib/storage/     SQLite isolate、DAO、迁移、blob 与 payload 编解码
lib/state/       AppSettings、SessionStore、TurnRunner、展示模型映射
lib/models/      聊天、工作区、设置和工具卡片模型
lib/platform/    路径守卫、工作区、系统文件/目录、窗口和设置适配
lib/ui/          聊天、侧栏、设置、查看器和浏览器界面
test/            领域、存储、工具、Agent 和布局冒烟测试
```

当前已经接通：

- 三种模型协议和纯聊天/工具循环。
- 工作区读写、编辑、删除、搜索、图片和网页工具，以及权限检查。
- Android HTML 内置浏览器、Windows 默认浏览器。
- 会话/工作区长按与右键菜单，Windows 分栏动画和点击反馈。
- Android 设置一级分类 → 二级配置页；Windows 左侧分类导航。
- 工具结果的文件跳转卡片、`edit_file` diff 卡片、网页来源卡片。

接手时不要重新实现上述功能；若发现行为问题，先定位现有唯一实现和对应测试。

## 下一阶段：全局记忆

目标是把当前设置页里的临时记忆数据替换为真正的 App 级持久化记忆，并接入三个模型可见工具：

```text
save_memory   新增或更新一条记忆
list_memory   按关键词/分类列出记忆
read_memory   读取一条完整记忆
```

约束：

- 记忆属于 App 私有数据，不属于当前会话工作区，也不能通过工作区文件工具访问。
- 除上述三个工具外，不允许其他工具读写记忆；`run_js` 也不能绕过权限边界。
- 工具入口统一校验参数、权限和结果状态；取消、拒绝、业务失败要区分。
- 维护单一结构化数据源，不同时写 `memory.json` 和数据库。
- 更新按明确的 `category + key` 规则执行，不做不可解释的自动合并。
- 设置页可查看、编辑、删除记忆，并能反映工具写入后的变化。

### 存储建议

存储设计已决定使用 SQLite，而不是 `memory.json`。建议在现有 storage isolate / DAO 体系中增加独立表和迁移，不让 UI 直接碰 SQLite。

至少需要：

```text
id            稳定主键
category      分类
key           更新键
content       记忆正文
tags          可选结构化标签
created_at    创建时间
updated_at    更新时间
```

`list_memory` 如果需要全文过滤，再评估 FTS5；先保证 CRUD、唯一更新规则、迁移和重启恢复正确，不要先做复杂检索抽象。

### 现有记忆代码的边界

- `lib/models/settings.dart` 的 `MemoryEntry` 只是展示模型。
- `lib/state/app_settings.dart` 当前把记忆保存在内存种子中，重启会恢复 mock 数据；这部分是下一阶段替换点。
- `lib/ui/settings/sections/memory_section.dart` 已有基础展示和删除界面，但需要改为监听真正的记忆仓储。
- `lib/state/tool_display.dart` 已有工具卡片映射入口，新记忆工具应在这里补充标题、图标和摘要，不要在 UI 里按工具名散落判断。
- `lib/tools/tool_registry.dart` 是工具唯一注册入口；权限规格也必须同步登记。

建议实现顺序：

1. 设计 SQLite 表、迁移和 DAO，先补单元/集成测试。
2. 增加记忆仓储接口，让设置页和工具共用同一数据源。
3. 实现三个工具及参数/权限/取消/失败测试。
4. 在 `ToolRegistry` 注册，接入 AgentLoop 的工具结果落库路径。
5. 替换设置页 mock 数据，补充编辑、删除、重启恢复验证。

## 不可破坏的不变量

- `entries` 是 append-only；旧条目不更新、不删除。撤回通过 truncate 标记完成。
- SQLite 只由 storage isolate 持有连接；UI isolate 不直接访问数据库。
- `Storage.close()` 的关闭顺序不要改成普通带 `_closed` 守卫的发送路径，否则 Windows 可能留下 SQLite 文件句柄。
- 网络、文件、JS 和图片操作要支持取消；页面销毁后不能继续更新 UI。
- 工作区路径必须经过 `WorkspaceGuard`；工具只能接收工作区相对路径。
- 工具写入必须经 `MutationQueue` 串行化；读类工具才可并行。
- API Key 只存本机设置，界面显示掩码；日志和错误不得暴露凭据、完整请求头或敏感响应。
- `lib/ai/messages.dart` 与 `lib/storage/models.dart` 有同名协议类型，跨层使用时保持 `ai` 别名和集中映射。
- `ToolResult` 的 `ok / failed / cancelled / denied` 是领域状态，不要用空字符串或 `null` 伪造成功。

## 当前已知欠账与小点打磨

按优先级从高到低：

1. 为 `openai-responses` 增加完整流式回归测试（正文、思考、工具分片、usage、错误、取消）。
2. 补“上次被中断，可重试”的界面提示；现有中断会话 ID 已由 bootstrap 暴露，但还没有完整 UI 消费路径。
3. 评估删除会话时是否提供“同时删除工作区”的明确选项；默认行为目前不会删除工作区文件。
4. 继续打磨文件树、附件、HTML 相对资源、来源卡片和触屏反馈，优先修真实使用中出现的问题。
5. 完善 Android 内置浏览器的下载、历史记录和清理入口；Windows 继续使用系统默认浏览器，不引入 WebView2。
6. 做真实平台验证：Android ABI/HTML WebView、Windows 原生焦点/窗口、Release 打包和 `sqlite3.dll`。

## 验证方式

代理可以执行的低成本检查：

```powershell
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

需要用户在真实环境执行的项目：

- Android 真机打开工作区 HTML，确认 `file://` 页面和相对资源加载。
- Android 长按、Windows 右键，以及 Windows 设置页滚动和焦点切换。
- 真实 API 的流式回复、工具权限弹窗、工具副作用和取消。
- Android 四 ABI、Windows Release 打包、杀进程恢复、断网/401/429/超时。

不要把未实际运行的真机、原生、联网或完整回归测试写成“通过”。

## 必读参考

- `AGENTS.md`：工程约束和协作边界
- `docs/WePChat-Flutter-实施TODO.md`：施工章节与代码注释引用
- `docs/WePChat-Flutter-会话存储设计.md`：append-only、迁移、压缩和 isolate 规则
- `docs/WePChat-Flutter-功能与工具协议.md`：工具 schema、权限和记忆协议
