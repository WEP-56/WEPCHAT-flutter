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
  return _buildToolCall(
    id: call.id,
    name: call.name,
    arguments: call.arguments,
    result: result,
    duration: elapsed == null ? null : _durationLabel(elapsed),
  );
}

/// 从持久化条目恢复卡片，保证重启前后文件跳转、diff 和来源展示一致。
ToolCall restoredToolCall({
  required String id,
  required String name,
  required Map<String, Object?> arguments,
  required String content,
  required ToolOutcome outcome,
  Map<String, Object?>? uiPayload,
}) {
  return _buildToolCall(
    id: id,
    name: name,
    arguments: arguments,
    result: ToolResult(
      content: content,
      outcome: outcome,
      uiPayload: uiPayload,
    ),
  );
}

ToolCall _buildToolCall({
  required String id,
  required String name,
  required Map<String, Object?> arguments,
  required ToolResult result,
  String? duration,
}) {
  final Map<String, Object?> ui = result.uiPayload ?? const <String, Object?>{};
  return ToolCall(
    id: id,
    kind: toolKindOf(name),
    title: toolTitleOf(name),
    meta: summarizeToolArguments(arguments),
    detail: _detailOf(result),
    file: _filePath(name, ui),
    fileChange: _fileChange(name, ui),
    sources: _sources(name, ui),
    status: result.outcome == ToolOutcome.ok
        ? ToolStatus.done
        : ToolStatus.failed,
    duration: duration,
  );
}

String? _filePath(String name, Map<String, Object?> ui) {
  if (!<String>{'read_file', 'write_file', 'edit_file'}.contains(name)) {
    return null;
  }
  final Object? path = ui['path'];
  return path is String && path.trim().isNotEmpty ? path : null;
}

FileChangePreview? _fileChange(String name, Map<String, Object?> ui) {
  if (name != 'edit_file') return null;
  final Object? rawPath = ui['path'];
  final Object? rawBefore = ui['find'];
  final Object? rawAfter = ui['replace'];
  final String? path = rawPath is String ? rawPath : null;
  final String? before = rawBefore is String ? rawBefore : null;
  final String? after = rawAfter is String ? rawAfter : null;
  final Object? rawCount = ui['replacements'];
  final int count = rawCount is int ? rawCount : int.tryParse('$rawCount') ?? 1;
  if (path == null || before == null || after == null) return null;
  return FileChangePreview(
    path: path,
    before: _capDiff(before),
    after: _capDiff(after),
    replacements: count,
  );
}

String _capDiff(String value) =>
    value.length <= 1200 ? value : '${value.substring(0, 1200)}…';

List<SourceChip> _sources(String name, Map<String, Object?> ui) {
  if (name == 'web_fetch') {
    final Object? rawUrl = ui['url'];
    final String? url = rawUrl is String ? rawUrl : null;
    if (url == null) return const <SourceChip>[];
    final Uri? uri = Uri.tryParse(url);
    return uri == null || uri.host.isEmpty
        ? const <SourceChip>[]
        : <SourceChip>[SourceChip(uri.host, uri.host, url: url)];
  }
  if (name != 'web_search' || ui['results'] is! List) {
    return const <SourceChip>[];
  }
  final List<SourceChip> sources = <SourceChip>[];
  for (final Object? raw in ui['results']! as List) {
    if (raw is! Map) continue;
    final Object? rawUrl = raw['url'];
    if (rawUrl is! String) continue;
    final Uri? uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) continue;
    final String title =
        raw['title'] is String && (raw['title'] as String).trim().isNotEmpty
        ? raw['title'] as String
        : uri.host;
    sources.add(SourceChip(title, uri.host, url: rawUrl));
  }
  return sources;
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
