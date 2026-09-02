# WePChat Flutter 版：功能与工具协议

状态：功能边界初稿

目标平台：Android、Windows

## 1. 产品定位

WePChat 是一个 local-first 的轻量 LLM 聊天客户端。

它的核心不是完整 coding agent，而是让用户可以快速完成以下事情：

- 日常问答和模型连通性验证
- 联网搜索并阅读资料
- 在当前会话工作区内生成、读取和修改文件
- 运行受限 JavaScript，完成计算、编码转换和文本处理
- 记录少量结构化的个人长期记忆
- 在普通对话中生成或编辑图片
- 快速生成 HTML、CSS、JavaScript 等可预览产物

产品不负责提供完整终端、项目构建环境、后台服务、浏览器自动化或多 Agent 编排。

## 2. 核心边界

### 2.1 会话与工作区

创建会话时自动创建并绑定一个工作区：

```text
用户设置的工作区根目录/
└── <session_id>/
    ├── 用户上传的文件
    ├── LLM 生成的文件
    ├── 脚本输出
    ├── 生成的图片
    └── 其他会话产物
```

- 工作区目录使用稳定的 `session_id`，不使用会话标题。
- 会话标题默认取用户第一句话的前几个字，仅用于界面显示。
- 用户不能在会话内切换工作区。
- 设置中的工作区根路径只影响新建会话，不迁移旧会话。
- 工作区长期保留，由用户自行删除；自动清理以后再考虑。
- 所有文件、脚本和图片工具只能操作当前会话工作区。
- 工具不能通过参数访问工作区以外的文件路径。

### 2.2 全局记忆是受控例外

全局记忆不属于任何单个会话工作区，由 App 私有存储维护：

```text
App 私有数据目录/
└── memory.json
```

只有 `save_memory`、`list_memory`、`read_memory` 可以访问该文件；普通文件工具和 `run_js` 都不能读取它。

## 3. 工具总表

### 3.1 网络工具

| 工具 | 作用 |
|---|---|
| `web_search` | 广泛发现候选来源，返回结果列表、摘要和来源标识 |
| `web_fetch` | 专一读取一个已知来源，返回正文或结构化内容 |

所有网络搜索统一从 `web_search` 进入，包括 OpenAI、Anthropic 等供应商的原生搜索能力。

### 3.2 工作区工具

| 工具 | 作用 |
|---|---|
| `list_files` | 查看工作区文件树 |
| `search_files` | 在工作区文本文件中搜索内容 |
| `read_file` | 读取一个工作区文本文件或片段 |
| `write_file` | 创建或完整写入工作区文本文件 |
| `edit_file` | 对已有文本文件做小范围精确修改 |
| `delete_file` | 删除工作区文件或目录，受权限设置控制 |

不单独提供 `create_folder`：`write_file` 自动创建父目录。

不把重命名、移动、导入、导出、预览设计成模型工具，优先由 App UI 完成。

### 3.3 脚本工具

| 工具 | 作用 |
|---|---|
| `run_js` | 在受限 JavaScript 运行时中处理工作区数据并生成结果 |

### 3.4 记忆工具

| 工具 | 作用 |
|---|---|
| `save_memory` | 新增或更新一条全局结构化记忆 |
| `list_memory` | 查看全局记忆的摘要和索引 |
| `read_memory` | 读取指定记忆的完整内容 |

### 3.5 图片工具

| 工具 | 作用 |
|---|---|
| `gen_image` | 根据提示词生成图片并保存到工作区 |
| `edit_image` | 读取工作区图片，按提示词生成编辑后的新图片 |

图片工具属于普通对话工具，不设置独立生图模式。

## 4. `web_search` 与 `web_fetch` 边界

### 4.1 `web_search`：广泛发现

`web_search` 解决的问题是：

> 我还不知道应该看哪些网页，请帮我找候选来源。

建议参数：

```json
{
  "query": "搜索问题",
  "freshness": "none|day|week|month|year",
  "domains": ["example.com"],
  "max_results": 5
}
```

行为约束：

- 返回多个候选来源，而不是一个网页的完整正文。
- 返回 `source_id`、标题、URL、摘要、发布时间和来源名称。
- 优先返回可引用的结果。
- `domains` 用于限制搜索范围，不用于绕过网络策略。
- `max_results` 建议限制在 1～8。
- 搜索结果不应直接当作完整事实；需要深入阅读时调用 `web_fetch`。
- 不允许通过 `web_search` 发送任意 HTTP 请求或自定义 Header。

典型使用：

```text
“查一下 2026 年 Flutter QuickJS 的可用方案”
“找三篇关于某主题的论文”
“最近某产品的价格是多少”
```

### 4.2 `web_fetch`：专一读取

`web_fetch` 解决的问题是：

> 我已经知道要读哪个网页，请把这个来源的内容提取出来。

建议参数：

```json
{
  "target": "source_id 或完整 https URL",
  "max_chars": 20000
}
```

行为约束：

- 一次只读取一个来源。
- `target` 可以是 `web_search` 返回的 `source_id`，也可以是用户直接提供的 URL。
- HTML 提取正文；PDF 提取可读文本；无法解析时返回明确错误。
- 返回最终 URL、标题、正文、内容类型和来源信息。
- 不负责发现更多网页，不自动递归抓取站内链接。
- 不支持模型自定义 Cookie、Authorization 或任意请求头。
- 第一版只允许 GET；POST、任意 API 调用和网页表单提交属于后续高级能力。

典型使用：

```text
web_search → 选中一个结果 → web_fetch
用户直接发来一个文档 URL → web_fetch
```

### 4.3 搜索后端统一路由

模型只看到 `web_search` 和 `web_fetch`，不直接看到供应商原生工具名。当前实现支持 Tavily、Exa、Serper、SearXNG（自建）以及自定义搜索服务；OpenAI/Anthropic 原生搜索不作为当前后端。

```text
web_search
    └── SearchBackend
        ├── Tavily
        ├── Brave
        ├── SearXNG
        ├── OpenAI 原生搜索
        └── Anthropic 原生搜索
```

搜索配置独立于聊天模型配置。用户可以使用 DeepSeek 聊天，同时使用 OpenAI、Tavily 或 Brave 的搜索 Key。

供应商原生搜索只作为后端适配实现；其版本、计费和引用格式由适配器转换为统一的 `web_search` 工具结果。

## 5. 工作区工具协议

### `list_files`

```json
{
  "path": "可选目录",
  "recursive": true
}
```

返回文件树、文件类型、大小和修改时间。返回内容必须受数量和字符数限制。

### `search_files`

```json
{
  "query": "搜索文本",
  "path": "可选目录",
  "glob": "可选，例如 **/*.md",
  "use_regex": false,
  "max_matches": 50
}
```

只搜索可读文本文件，跳过图片、压缩包和其他二进制文件。

### `read_file`

```json
{
  "path": "README.md",
  "lines": "1-80"
}
```

读取结果必须截断，避免把大文件一次性送入上下文。

### `write_file`

```json
{
  "path": "src/main.js",
  "content": "完整文件内容"
}
```

适合新建文件或完整重写文件。父目录自动创建。覆盖已有文件时遵循全局权限设置。

### `edit_file`

```json
{
  "path": "src/main.js",
  "find": "旧文本",
  "replace": "新文本",
  "all": false
}
```

调用前模型应先读取文件。默认精确匹配；匹配失败时返回错误，不猜测修改位置。

### `delete_file`

```json
{
  "path": "old.md"
}
```

删除权限由用户的全局工具设置决定。工具不得在返回前声称文件已经删除。

## 6. `run_js` 运行时

### 6.1 定位

`run_js` 是工作区脚本工具，不是 Node.js、Python 或 Shell 环境。

它主要服务于：

- 编码转换和解码
- 文本、JSON、CSV 处理
- 正则批处理
- 数学计算和大整数运算
- 简单哈希、压缩和格式转换
- 批量读取和写入工作区文件
- 生成配置、报告和其他文本产物

### 6.2 运行时能力

建议使用 QuickJS 系列引擎，通过 FFI 集成到 Android 和 Windows。业务代码只依赖自定义的 `WepJsRuntime` 抽象，不直接绑定某个 Flutter 插件。

候选实现包括 `quickjs_engine` 和 `fjs`；正式选型前必须验证 native 构建、Isolate、超时中断和发布包体积。

脚本可使用标准 JavaScript 能力，以及 App 注入的工作区桥接：

```javascript
const files = await wep.fs.listFiles();
const source = await wep.fs.readText("input.txt");
await wep.fs.writeText("output.txt", transform(source));
console.log("处理完成");
```

### 6.3 权限和限制

- JS 只能访问当前会话工作区。
- JS 不接触真实设备路径。
- 默认关闭网络、DOM、Shell、进程、环境变量和系统 API。
- 可以读写工作区中的文本文件和受控二进制表示。
- 文件写入由 Dart 宿主检查并串行化。
- 每次调用默认创建独立 JS context，结束后销毁。
- 必须支持超时、取消、输出大小和文件大小限制。
- 建议初始值：执行 8～15 秒、输出 16～64 KB、单文件读取 512 KB～2 MB。

第一版不支持运行时联网下载 npm 依赖。需要第三方能力时，只允许使用随 App 一起发布并经过审核的纯 JS 库。

### 6.4 Flutter 侧需要重点验证的点

1. JS 执行不能阻塞 Flutter UI。
2. `Future.timeout` 不能替代真正的 native JS 中断机制。
3. QuickJS 的 interrupt callback 或等价机制必须能够终止死循环。
4. Android 各 ABI 和 Windows 发布包都要能加载 native 库。
5. Dart↔JS 的字符串、字节数组、异常和 Promise 转换要有测试。

## 7. 全局记忆协议

### 7.1 存储

第一版使用一个 App 私有的结构化文件：

```text
memory.json
```

建议条目结构：

```json
{
  "id": "pref_ui_style",
  "category": "preference",
  "key": "ui_style",
  "value": "偏好简洁、低干扰的界面",
  "updated_at": "2026-08-30T12:00:00Z"
}
```

不保存整段聊天记录，不保存密码、API Key 和临时任务。

### 7.2 工具行为

`save_memory(category, key, value)`：相同 `category + key` 时更新，否则新增。

`list_memory(category?)`：只返回 ID、类别、Key 和摘要，不默认返回所有全文。

`read_memory(id)`：读取指定条目的完整内容。

### 7.3 LLM 使用规则

记忆功能开放时，system prompt 应明确要求：

- 新会话开始时先调用 `list_memory` 了解全局记忆。
- 发现与当前问题相关的条目后再调用 `read_memory`。
- 只有用户明确表达稳定偏好、身份背景、项目背景或长期习惯时才调用 `save_memory`。
- 相同 Key 使用更新，不重复制造条目。

设置为全局三档：

- 关闭：不向模型暴露记忆工具。
- 询问：每个新会话开始时询问用户是否开放记忆。
- 允许：自动暴露记忆工具。

用户可以在设置页查看、编辑和删除记忆。

## 8. 图片工具

### `gen_image`

根据用户需求调用图片生成接口，生成结果自动写入当前工作区。

建议参数：

```json
{
  "prompt": "完整图片描述",
  "size": "可选尺寸",
  "count": 1
}
```

### `edit_image`

读取当前工作区中的图片并调用图片编辑接口：

```json
{
  "image_file": "images/source.png",
  "prompt": "把背景改成夜晚",
  "size": "可选尺寸"
}
```

规则：

- `image_file` 必须位于当前工作区。
- 生成和编辑都由 App 自动命名文件，模型不能指定任意路径。
- 编辑默认生成新文件，不覆盖原图。
- 建议文件名格式：`images/日期时间-短 ID.png`。
- 返回图片 Artifact、工作区路径和尺寸信息。

## 9. 权限设置

每个工具拥有全局权限设置：

```text
禁止 / 询问 / 允许
```

设置作用于所有会话，不提供会话级特例。

权限检查应发生在工具执行前，工具结果中记录：

- 工具名称
- 参数摘要
- 是否需要确认
- 执行状态
- 错误信息
- 产生的文件和引用

建议默认值：

| 工具类型 | 默认值建议 |
|---|---|
| `list_files`、`search_files`、`read_file` | 允许 |
| `write_file`、`edit_file` | 询问或允许 |
| `delete_file` | 询问 |
| `web_search`、`web_fetch` | 允许或询问 |
| `run_js` | 询问 |
| `save_memory`、`list_memory`、`read_memory` | 按记忆总开关决定 |
| `gen_image`、`edit_image` | 允许 |

## 10. Agent Core 复刻范围

只学习和复刻 pi 的基础部分，不做 pi GUI 客户端，也不移植完整 coding harness。

### 10.1 应复刻

- Provider 抽象和统一流式响应
- Assistant message、tool call、tool result 数据结构
- Agent loop
- 工具参数校验
- 工具串行与并行执行
- 中止、重试和错误恢复
- 上下文裁剪与压缩
- steering/follow-up 消息
- 工具执行生命周期事件
- 可动态启用和禁用工具

### 10.2 不应复刻

- TUI
- `bash`、PowerShell 和终端工作流
- 本地后台服务
- 完整 coding-agent harness
- 本地 MCP 进程管理
- 多 Agent 和子 Agent
- 复杂扩展市场

### 10.3 建议的 Dart 分层

```text
wep_ai
  Provider、模型、流式协议、原生搜索适配

wep_agent_core
  Agent loop、消息、事件、上下文、重试、压缩

wep_tools
  web、workspace、run_js、memory、image 工具

wep_storage
  会话、工作区、memory.json、附件和图片

wep_runtime
  QuickJS、Dart Isolate、权限、取消和资源限制

Flutter UI
  聊天、工具卡片、设置、工作区、图片和预览
```

前端不应该为每个工具实现一套独立状态机，而是统一消费 Agent 事件：

```text
agent_start
turn_start
message_update
tool_execution_start
tool_execution_update
tool_execution_end
turn_end
agent_end
```

## 11. 首版范围

### P0

- 会话和工作区绑定
- OpenAI-compatible、Anthropic 等基础模型适配
- Agent loop 和流式消息
- `web_search`、`web_fetch`
- `list_files`、`search_files`、`read_file`、`write_file`、`edit_file`、`delete_file`
- `run_js` 最小可用运行时
- `save_memory`、`list_memory`、`read_memory`
- `gen_image`、`edit_image`
- 图片、附件和文本产物写入工作区

### P1

- HTML/CSS/JS 自动预览
- 文件 diff 展示
- 工具运行详情和错误重试
- Tavily、Brave 等搜索 Profile
- OpenAI/Anthropic 原生搜索后端
- Android 文件导入和 Windows 文件夹设置
- 工作区文件导出

下一阶段工作区增强：

- 更多文件类型的识别、查看与编辑
- 附件上传与工作区文件导出
- HTML/CSS/JavaScript 真实预览
- 工作区文件的增删查改能力完善
- 内置真实浏览器，HTML 预览基于浏览器内核实现

内置浏览器参考实现：`example/fluxdo`。

### P2

- 远程 MCP
- 自定义工具包
- 更丰富的 JS 内置模块
- 工作区全文索引
- 可选的复杂项目执行后端

## 12. 明确不承诺

WePChat 不承诺：

- 运行任意 Node.js/Python/Shell 代码
- 自动管理依赖和编译环境
- 自动操作用户整个磁盘
- 自动浏览登录态网页
- 自动运行长期后台服务
- 自动保存全部聊天内容为记忆
- 对第三方搜索服务的稳定性、额度和价格负责

这些能力如果未来需要，应作为独立高级扩展，而不是破坏核心产品的轻量边界。

## 参考资料

- [WePChat 原有工具文档](https://github.com/WEP-56/WePChat/blob/main/docs/tools.md)
- [Pi coding-agent README](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/README.md)
- [Pi Agent Loop / Extensions 文档](https://pi.dev/docs/latest/extensions)
- [OpenAI Web Search](https://developers.openai.com/api/docs/guides/tools-web-search)
- [Anthropic Web Search Tool](https://docs.anthropic.com/en/docs/build-with-claude/tool-use/web-search-tool)
