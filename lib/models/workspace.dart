import 'content.dart';

/// 工作区文件类型。名称与扩展名一致，便于从文件名解析。
enum FileKind {
  md,
  csv,
  py,
  js,
  ts,
  css,
  yaml,
  xml,
  png,
  jpg,
  html,
  json,
  pdf,
  txt,
}

class WorkspaceFile {
  const WorkspaceFile({
    required this.name,
    required this.kind,
    required this.size,
    required this.time,
  });

  /// 工作区内的相对路径，例如 `images/cover_v1.png`。
  final String name;
  final FileKind kind;

  /// 展示用的体积文本（mock 数据不做真实统计）。
  final String size;

  /// 展示用的修改时间文本。
  final String time;

  bool get isImage => kind == FileKind.png || kind == FileKind.jpg;
}

/// 会话工作区路径。目录名使用稳定的 `session_id`，不使用会话标题
/// （功能协议 §2.1）。
String sessionWorkspacePath(String workspaceRoot, String sessionId) {
  return '$workspaceRoot/$sessionId';
}

/// 文件预览内容。第一版只覆盖能在纯前端里渲染的几种形态。
sealed class FileBody {
  const FileBody();
}

/// 富文本（Markdown 类）预览。
class BlocksFileBody extends FileBody {
  const BlocksFileBody(this.blocks);

  final List<ContentBlock> blocks;
}

/// 代码 / 纯文本预览。
class CodeFileBody extends FileBody {
  const CodeFileBody(this.lang, this.code);

  final String lang;
  final String code;
}

/// 表格预览。
class CsvFileBody extends FileBody {
  const CsvFileBody(this.head, this.rows);

  final List<String> head;
  final List<List<String>> rows;
}

/// HTML 产物，可交给系统默认浏览器打开。
class HtmlFileBody extends FileBody {
  const HtmlFileBody();
}

/// 二进制文档，只能展示元信息。
class BinaryFileBody extends FileBody {
  const BinaryFileBody(this.note);

  final String note;
}
