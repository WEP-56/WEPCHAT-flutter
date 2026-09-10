# MCP 高级功能

入口：**设置 → 高级功能**。MCP 默认关闭，已有安装升级后也保持关闭。

开启总开关时，应用会明确说明：**MCP 工具由外部服务器执行，不受 WePChat 工作区门禁限制**。本地服务器可以访问工作区外的文件或启动程序，远程服务器可以产生外部服务副作用。用户确认后才启用。内置文件、脚本和图片工具继续遵守原有工作区限制。

## 平台与配置

| 连接方式 | Android | Windows |
| --- | --- | --- |
| Streamable HTTP | 支持 | 支持 |
| 旧式 HTTP + SSE | 支持 | 支持 |
| stdio 本地进程 | 不支持 | 支持 |

网络服务器的认证方式有两种：

| 认证方式 | Streamable HTTP | 旧式 SSE |
| --- | --- | --- |
| 固定请求头 | 支持 | 支持 |
| OAuth 登录 | 支持 | 不支持 |

旧式 SSE 传输没有 OAuth 入口，只能在请求头里放一个固定令牌（例如 API Key）。需要浏览器交互登录的服务器必须使用 Streamable HTTP。像 Asana 这类只提供 SSE 端点、又只支持 OAuth 的服务器当前无法接入。

1. 添加服务器，填写名称、连接方式和对应参数。
2. 固定请求头：在请求头 JSON 中填写凭据，例如 `{"Authorization":"Bearer your_token_here"}`。无请求头填写 `{}`。
3. OAuth 登录：认证方式选“OAuth 登录”。客户端 ID、客户端密钥、权限范围、回调端口全部留空即可——服务器支持动态客户端注册或 Client ID Metadata Document 时会自动完成注册。只有服务器要求预注册客户端时才需要填客户端 ID。回调端口留空使用系统分配的临时端口，服务器不接受临时端口时才填写固定值。
4. Windows stdio 分别填写可执行文件和 JSON 参数数组。需要自行安装 Node.js/npm 或 uv；应用不会安装运行环境。
5. 启用 MCP 后点击“测试连接”，查看发现的工具。stdio 测试会启动本地进程，npx/uvx 可能下载服务器依赖。再次点击可以取消测试。
6. 按服务器设置“禁止 / 询问 / 允许”。默认询问，权限适用于该服务器的全部工具；“本会话一直允许”的临时授权也按服务器生效。

## OAuth 登录

点服务器卡片上的“登录授权”开始：

1. 应用在 `127.0.0.1` 上起一个临时回调端口。
2. 向 MCP 服务器发一个未认证请求，服务器返回 `401` 与 `WWW-Authenticate` 挑战。
3. 应用按 MCP 授权规范完成受保护资源元数据发现（RFC 9728）与授权服务器发现（RFC 8414 / OpenID Connect Discovery 1.0），构造授权地址。
4. **先弹窗展示授权服务器域名与请求的权限范围，确认后才打开系统浏览器。** 授权服务器与 MCP 服务器不同源是常态，这一步不会自动跳过。
5. 浏览器登录完成后回跳回环地址，应用校验 `state` 与 `iss`，换取令牌并保存在本机。

登录行为的约束：

- **聊天过程中不会弹出浏览器。** 令牌缺失或失效时，本轮连接直接报“尚未登录授权”，由用户自己决定何时去设置里登录。授权必须由用户主动发起。
- 令牌连同它被授权的授权服务器与受保护资源一起保存。服务器换了授权服务器时，旧令牌会被拒绝而不是被复用。
- 访问令牌过期后，应用用 `refresh_token` 静默刷新一次。刷新失败会清除令牌并要求重新登录，不会拿失效令牌反复重试。
- 修改服务器的地址、传输方式或客户端 ID 会作废已保存的令牌，因为它们意味着换了一个授权目标。
- 令牌保存在 App 私有 `settings.json` 的 `mcpAuth` 键下，**不进入 WebDAV 可移植备份**，也不跨设备同步。清除它用服务器卡片上的“退出登录”。
- 授权委托给系统浏览器是规范要求，多数身份提供商也会拒绝应用内 WebView 发起的授权请求。

Windows 文件服务配置示例：

```text
连接方式：stdio
可执行文件：npx
```

参数使用 JSON 字符串数组：

```json
["-y", "@modelcontextprotocol/server-filesystem", "D:\\mcp-data"]
```

路径仅为示例，应替换为用户准备的目录。`npx` 的标准 Windows 包装脚本会解析到 Node.js 的 npm CLI，参数不经 shell 拼接。uvx 也使用程序名和参数数组；自定义批处理脚本需要显式指定解释器。

工作目录可留空，留空使用当前会话工作区。**工作目录不是沙箱**，不会限制服务器读取其他目录。环境变量使用字符串键值 JSON；应用只继承 PATH、系统目录、用户目录、临时目录等运行所需变量，其他变量需显式配置。

服务器配置和凭据保存在应用私有 `settings.json`。当前 WebDAV 可移植备份不包含 MCP 配置，避免在其他设备自动启用本地命令或继承授权。

## 调用与生命周期

- 每轮对话创建自己的 MCP 连接和工具快照，同一轮内复用，结束后关闭；服务器进程内存状态不会跨聊天轮次保留。
- 未启用 MCP 时不会创建连接。禁用的服务器和权限为“禁止”的服务器不会加入聊天工具列表。
- MCP 工具通过 `ToolRegistry` 执行参数校验和权限检查；工具名带稳定的 `mcp_` 命名空间，原始名称用于调用服务器。
- MCP 调用进入当前工作区的同一写入队列，避免与本轮内置文件工具并发修改文件。外部服务器自主产生的其他操作不受这个队列控制。
- 工具完成事件即时发出，结果及时持久化；给模型回传的结果仍保持原工具调用的配对顺序。
- 关闭 MCP、改变配置、停止对话或退出应用时，会取消相关调用并清理连接。Windows 会结束所拥有的进程树。
- **取消、超时和断线不能撤销服务器已经产生的副作用。** 应用不会为工具调用自动重试；失效的 HTTP 会话也不会触发 SDK 自动重发原调用。
- 请求超时可设置为 1–600 秒。最多配置 16 台服务器，每轮最多发现 256 个 MCP 工具；输出复用现有工具截断逻辑。

## 当前支持范围

当前提供 MCP **tools 客户端**：初始化／协议协商、分页发现工具、调用工具、参数验证、请求取消和连接关闭。

结果支持文本、结构化 JSON、内嵌文本资源和资源链接。图片、音频及其他二进制内容会明确报告暂不支持，并保留同次返回的文本，不会伪装成成功展示。

网络认证支持固定请求头和 OAuth 登录（仅 Streamable HTTP）。OAuth 的协议实现全部来自 SDK：`WWW-Authenticate` 挑战解析、受保护资源元数据与授权服务器发现、PKCE S256、`state`/`iss` 校验、RFC 8707 `resource` 参数、按协议优先级选择客户端注册方式（预注册 → Client ID Metadata Document → 动态注册）以及授权码交换。应用只补齐令牌存储、回环回调和浏览器跳转。

暂不提供资源浏览、prompts、sampling、elicitation 和任务扩展。MCP 的外部 schema 保留原义；具体模型供应商仍需支持该 schema。

## 代码入口

- `lib/mcp/`：纯 Dart 配置、连接契约、SDK 适配和每轮连接所有权。
- `lib/mcp/mcp_oauth.dart`：令牌数据对象与存储契约。
- `lib/mcp/mcp_auth_storage.dart`：令牌的内存持有与序列化。
- `lib/mcp/mcp_oauth_provider.dart`：SDK 授权码 provider，以及会话内只读 provider。
- `lib/mcp/mcp_oauth_refresh.dart`：`refresh_token` 静默刷新。
- `lib/mcp/mcp_oauth_redirect.dart`：回环回调监听。
- `lib/mcp/mcp_oauth_login.dart`：登录编排（发现 → 确认 → 浏览器 → 回跳 → 换令牌）。
- `lib/mcp/mcp_error_text.dart`：MCP 错误到用户文案的唯一映射入口。
- `lib/platform/mcp_transports.dart`：传输选择、OAuth 挂载与平台能力检查。
- `lib/platform/mcp_windows_stdio.dart`：Windows 程序解析、环境变量和进程清理。
- `lib/tools/mcp_tool.dart`：统一工具管线适配，明确绕过工作区路径检查。
- `lib/state/mcp_controller.dart`：设置变更、连接测试、OAuth 登录与宿主生命周期。
- `lib/ui/settings/sections/advanced_section.dart`：启用说明、服务器管理和登录状态。

使用 MIT 许可的纯 Dart `mcp_dart 2.4.2`，未新增原生库，也未新增平台清单项（OAuth 用回环地址而不是自定义 URL scheme）。SDK 类型封装在基础设施层。

## 建议用户执行的验证

已执行的检查（Agent 侧）：

```bash
flutter analyze
flutter test test/mcp test/state/mcp_controller_test.dart test/tools/mcp_tool_test.dart
```

`flutter analyze` 只有既有文件的历史 info，本次新增代码无新增问题。MCP 测试 44 项全部通过，其中 `mcp_oauth_login_test.dart` 在临时回环服务上跑完整个授权码流程（401 → 受保护资源元数据 → 授权服务器元数据 → 动态客户端注册 → PKCE → 回环回调 → 令牌交换 → 落盘），不依赖外部服务或密钥。

尚未执行：`dart format`、真机、真实服务器、完整构建与打包。

```bash
flutter test test/mcp test/state/mcp_controller_test.dart test/tools/mcp_tool_test.dart test/platform/mcp_stdio_launch_test.dart test/agent/tool_completion_test.dart test/core/cancellation_token_test.dart test/tools/permission_gate_test.dart
```

实际设备请验证：

- 默认关闭；取消启用说明后仍关闭；确认开启后重启保留设置。
- Android、Windows 分别连接真实 Streamable HTTP 和旧式 SSE 服务器。
- **OAuth 真机验证**（建议顺序：先 Linear，再 Sentry / Notion，最后挑一个要求预注册客户端的服务器验证客户端 ID 输入框）：
  - 点“登录授权”后先看到授权域名与权限范围确认框，确认后才跳出浏览器。
  - 浏览器登录完成、回跳到 `127.0.0.1` 后应用自动完成授权并显示“已登录”。
  - 登录成功后点“测试连接”能发现工具；重启应用后仍是已登录状态。
  - 令牌过期后能用 `refresh_token` 自动续期；把 refresh_token 失效后应提示重新登录而不是静默失败。
  - 未登录时直接开始一轮对话，应报“尚未登录授权”且**不弹出浏览器**。
  - “退出登录”后令牌消失、状态回到未登录，且不进入 WebDAV 可移植备份。
  - 服务器不接受临时端口时，填固定回调端口后重新登录成功；端口被占用时给出包含端口号的错误。
- Windows 分别运行 npx/uvx，检查含空格与中文的路径、认证环境变量，以及结束对话后进程退出。Windows 上还需验证打开默认浏览器以及 `127.0.0.1` 回跳能被浏览器放行。
- Android 不显示可新建的 stdio 选项，已有 stdio 配置会明确标记不支持且执行被拒绝。
- MCP 参数可按服务器约定访问工作区之外的位置；相同越界路径仍被内置文件工具拒绝。
- 禁止、询问、允许、取消连接测试、停止对话、配置变更、服务器异常退出与超时。
- 多个工具同时返回时，快工具及时显示结果；MCP 错误结果和历史工具卡片可正常显示。

未执行真实服务器、真机、完整构建、打包或性能验证。
