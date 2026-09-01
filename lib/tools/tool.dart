/// 工具的执行契约（实施 TODO §7-1）。
///
/// 和 `ToolDefinition`（`lib/ai/provider_api.dart`）的分工：那边是**给模型看
/// 的声明**（名字 / 描述 / schema，进请求体、影响缓存前缀），这边是**给程序
/// 用的实现**。一个工具同时给出两者，但两者的生命周期不同——声明改一个字
/// 就废掉整个 prompt 缓存（§7.1），实现改多少次都没事。
library;

import '../core/cancellation_token.dart';
import '../ai/provider_api.dart';

/// 工具执行结果。
///
/// 不用抛异常表示失败：失败要回传给模型让它自己纠正，而不是中断整个 loop
/// （§7-5）。所以错误是一等结果，[isError] 为 true 时 [content] 是给模型
/// 看的错误说明。
class ToolResult {
  const ToolResult({
    required this.content,
    this.isError = false,
    this.uiPayload,
  });

  /// 成功结果。
  factory ToolResult.ok(String content, {Map<String, Object?>? uiPayload}) {
    return ToolResult(content: content, uiPayload: uiPayload);
  }

  /// 失败结果。[content] 要写成模型能据此改正的话，不是给人看的堆栈。
  factory ToolResult.error(String content) {
    return ToolResult(content: content, isError: true);
  }

  /// 回传给模型的文本。
  final String content;

  final bool isError;

  /// 只给界面用的结构化数据（比如 diff、文件树），不进请求体。
  ///
  /// 分开是因为界面想要结构，模型只要文本——把 JSON 塞给模型既浪费 token
  /// 又不如自然语言好懂。
  final Map<String, Object?>? uiPayload;
}

/// 工具执行时能拿到的环境。
///
/// 走参数而不是全局：同一个进程里可能有多个会话，各自的工作区不同，
/// 全局状态会让两个会话互相写到对方目录里去。
class ToolContext {
  const ToolContext({
    required this.sessionId,
    required this.workspaceRoot,
    required this.token,
  });

  final String sessionId;

  /// 这个会话的工作区根目录。文件类工具必须把路径限制在这个目录内
  /// （§7-4 的越界检查）。
  final String workspaceRoot;

  /// 用户中断时会被取消。长操作要在关键点检查（§3-1）。
  final CancellationToken token;
}

/// 一个工具。
abstract class Tool {
  const Tool();

  /// 进请求体的声明。名字在同一注册表内唯一。
  ToolDefinition get definition;

  String get name => definition.name;

  /// 执行是否需要用户确认（§7-6）。
  ///
  /// 读类工具返回 false，写类和执行命令类返回 true。判断放在工具自己身上
  /// 而不是调用方的 if-else：新加一个工具时忘了改那串 if-else，就等于默认
  /// 放行，而默认放行的错误方向是不可逆的。
  bool get requiresApproval => false;

  /// 执行。
  ///
  /// [arguments] 已经是解析好的 Map（适配器保证，§4-7），但**内容未经校验**
  /// ——模型会传错类型、缺字段、给越界路径，实现里必须自己检查并返回
  /// [ToolResult.error]。
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  );
}
