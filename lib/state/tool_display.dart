/// 工具调用 ↔ 展示模型的映射（实施 TODO §10-3）。
///
/// `AgentToolStart` / `AgentToolEnd` 翻成聊天里的工具卡片。放在
/// `state/` 而不是 `ui/`：这是领域事件到展示模型的派生，界面只负责画
/// （AGENTS.md §2.2）。
library;

import '../ai/messages.dart' as ai;
import '../models/tool_call.dart';
import '../tools/tool.dart';
import '../tools/tool_summary.dart';

/// 工具名 → 卡片图标类别。
///
/// 认不出的工具归到 `script`：一个新工具忘了登记时显示成通用图标，
/// 比整条链路抛异常好。
ToolKind toolKindOf(String name) {
  return switch (name) {
    'web_search' => ToolKind.search,
    'web_fetch' => ToolKind.fetch,
    'run_js' => ToolKind.script,
    'gen_image' || 'edit_image' => ToolKind.image,
    'save_memory' || 'list_memory' || 'read_memory' => ToolKind.memory,
    'list_files' ||
    'search_files' ||
    'read_file' ||
    'write_file' ||
    'edit_file' ||
    'delete_file' => ToolKind.file,
    _ => ToolKind.script,
  };
}

/// 工具名 → 卡片标题。模型看到的是英文名，用户看到的应该是中文。
String toolTitleOf(String name) {
  return switch (name) {
    'list_files' => '列出文件',
    'search_files' => '搜索文件',
    'read_file' => '读取文件',
    'write_file' => '写入文件',
    'edit_file' => '编辑文件',
    'delete_file' => '删除文件',
    'web_search' => '联网搜索',
    'web_fetch' => '网页读取',
    'run_js' => '运行脚本',
    'gen_image' => '生成图片',
    'edit_image' => '编辑图片',
    _ => name,
  };
}

/// 执行中的卡片。
ToolCall runningToolCall(ai.ToolCallPart call) {
  return ToolCall(
    id: call.id,
    kind: toolKindOf(call.name),
    title: toolTitleOf(call.name),
    meta: summarizeToolArguments(call.arguments),
    status: ToolStatus.running,
  );
}

/// 执行完的卡片。
///
/// 四态收成两种视觉：成功是对勾，其余三种都是叹号，但 [ToolCall.detail]
/// 里的文案不同——用户要能分清"文件不存在"和"你自己拒绝了"。
ToolCall finishedToolCall(
  ai.ToolCallPart call,
  ToolResult result, {
  Duration? elapsed,
}) {
  return ToolCall(
    id: call.id,
    kind: toolKindOf(call.name),
    title: toolTitleOf(call.name),
    meta: summarizeToolArguments(call.arguments),
    detail: _detailOf(result),
    status: result.outcome == ToolOutcome.ok
        ? ToolStatus.done
        : ToolStatus.failed,
    duration: elapsed == null ? null : _durationLabel(elapsed),
  );
}

/// 卡片折叠时那一行的摘要。
///
/// 结果正文可能很长（`read_file` 会带整个文件），这里只取第一行：
/// 完整内容在展开区和落库的条目里。
String _detailOf(ToolResult result) {
  final String prefix = switch (result.outcome) {
    ToolOutcome.ok => '',
    ToolOutcome.failed => '失败：',
    ToolOutcome.cancelled => '已中断：',
    ToolOutcome.denied => '已拒绝：',
  };
  final String firstLine = result.content.split('\n').first.trim();
  final String brief = firstLine.length <= 120
      ? firstLine
      : '${firstLine.substring(0, 120)}…';
  return '$prefix$brief';
}

String _durationLabel(Duration d) {
  if (d.inMilliseconds < 1000) return '${d.inMilliseconds}ms';
  return '${(d.inMilliseconds / 1000).toStringAsFixed(1)}s';
}
