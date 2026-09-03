/// 模型可见的工具类别，决定卡片图标和展开区域的呈现方式。
enum ToolKind { search, fetch, script, image, file, memory }

enum ToolStatus { running, done, failed }

/// `web_search` 返回的来源标识。
class SourceChip {
  const SourceChip(this.name, this.host, {this.url});

  final String name;
  final String host;
  final String? url;
}

/// 文件工具完成后展示的局部 diff。
class FileChangePreview {
  const FileChangePreview({
    required this.path,
    required this.before,
    required this.after,
    required this.replacements,
  });

  final String path;
  final String before;
  final String after;
  final int replacements;
}

/// 一次工具调用的展示模型。
///
/// 纯前端阶段只承载渲染需要的字段；接入 Agent Core 后由工具事件填充。
class ToolCall {
  const ToolCall({
    required this.id,
    required this.kind,
    required this.title,
    this.detail,
    this.query,
    this.prompt,
    this.meta,
    this.note,
    this.found,
    this.file,
    this.fileChange,
    this.sources = const <SourceChip>[],
    this.status = ToolStatus.done,
    this.duration,
  });

  final String id;
  final ToolKind kind;

  /// 工具卡片标题，例如「联网搜索」。
  final String title;

  /// 一句话结果摘要。
  final String? detail;

  /// 搜索类工具的查询串。
  final String? query;

  /// 图片类工具的提示词。
  final String? prompt;

  /// 参数摘要，例如 `path=report.md · lines=1-80`。
  final String? meta;

  /// 记忆类工具写入的条目摘要。
  final String? note;

  /// 命中数量文本，例如「找到 5 条来源」。
  final String? found;

  /// 可直接跳转的工作区文件。
  final String? file;

  final FileChangePreview? fileChange;

  final List<SourceChip> sources;
  final ToolStatus status;

  /// 耗时文本，例如 `1.8s`。
  final String? duration;

  bool get isRunning => status == ToolStatus.running;
}
