# MCP 高级功能

入口：**设置 → 高级功能**。MCP 默认关闭，已有安装升级后也保持关闭。

开启总开关时，应用会明确说明：**MCP 工具由外部服务器执行，不受 WePChat 工作区门禁限制**。本地服务器可以访问工作区外的文件或启动程序，远程服务器可以产生外部服务副作用。用户确认后才启用。内置文件、脚本和图片工具继续遵守原有工作区限制。

## 平台与配置

| 连接方式 | Android | Windows |
| --- | --- | --- |
| Streamable HTTP | 支持 | 支持 |
| 旧式 HTTP + SSE | 支持 | 支持 |
| stdio 本地进程 | 不支持 | 支持 |

1. 添加服务器，填写名称、连接方式和对应参数。
2. 网络服务器填写完整接口地址；如需认证，在请求头 JSON 中填写固定凭据，例如 `{"Authorization":"Bearer your_token_here"}`。无请求头填写 `{}`。
3. Windows stdio 分别填写可执行文件和 JSON 参数数组。需要自行安装 Node.js/npm 或 uv；应用不会安装运行环境。
4. 启用 MCP 后点击“测试连接”，查看发现的工具。stdio 测试会启动本地进程，npx/uvx 可能下载服务器依赖。再次点击可以取消测试。
5. 按服务器设置“禁止 / 询问 / 允许”。默认询问，权限适用于该服务器的全部工具；“本会话一直允许”的临时授权也按服务器生效。

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

暂不提供资源浏览、prompts、sampling、elicitation、任务扩展或 OAuth 登录流程。网络认证使用用户配置的固定请求头。MCP 的外部 schema 保留原义；具体模型供应商仍需支持该 schema。

## 代码入口

- `lib/mcp/`：纯 Dart 配置、连接契约、SDK 适配和每轮连接所有权。
- `lib/platform/mcp_transports.dart`：传输选择与平台能力检查。
- `lib/platform/mcp_windows_stdio.dart`：Windows 程序解析、环境变量和进程清理。
- `lib/tools/mcp_tool.dart`：统一工具管线适配，明确绕过工作区路径检查。
- `lib/state/mcp_controller.dart`：设置变更、连接测试和宿主生命周期。
- `lib/ui/settings/sections/advanced_section.dart`：启用说明和服务器管理界面。

使用 MIT 许可的纯 Dart `mcp_dart 2.4.2`，未新增原生库。SDK 类型封装在基础设施层。

## 建议用户执行的验证

以下测试代码已加入，**实现过程中未执行 `flutter test`**：

```bash
flutter test test/mcp test/state/mcp_controller_test.dart test/tools/mcp_tool_test.dart test/platform/mcp_stdio_launch_test.dart test/agent/tool_completion_test.dart test/core/cancellation_token_test.dart test/tools/permission_gate_test.dart
```

其中 `no_replay_http_transport_test.dart` 会启动本机临时 HTTP 服务，验证会话失效时工具只发送一次；其他 MCP 协议测试使用内存传输，不需要真实 API 或密钥。

实际设备请验证：

- 默认关闭；取消启用说明后仍关闭；确认开启后重启保留设置。
- Android、Windows 分别连接真实 Streamable HTTP 和旧式 SSE 服务器。
- Windows 分别运行 npx/uvx，检查含空格与中文的路径、认证环境变量，以及结束对话后进程退出。
- Android 不显示可新建的 stdio 选项，已有 stdio 配置会明确标记不支持且执行被拒绝。
- MCP 参数可按服务器约定访问工作区之外的位置；相同越界路径仍被内置文件工具拒绝。
- 禁止、询问、允许、取消连接测试、停止对话、配置变更、服务器异常退出与超时。
- 多个工具同时返回时，快工具及时显示结果；MCP 错误结果和历史工具卡片可正常显示。

未执行真实服务器、真机、完整构建、打包或性能验证。
