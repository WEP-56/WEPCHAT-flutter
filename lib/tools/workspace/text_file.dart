/// 文本文件的读写细节：BOM、行尾、二进制识别（实施 TODO §7-14）。
///
/// 抽出来是因为四个工具都要用：`read_file` 要剥 BOM，`edit_file` 要剥了再
/// 原样还原，`write_file` 要沿用原文件的行尾，`search_files` 要跳过二进制。
/// 四份各自实现的下场是 `edit_file` 把 CRLF 文件改成混合行尾，而
/// `read_file` 看不出来（AGENTS.md §1.2）。
library;

import 'dart:convert';
import 'dart:io';

/// UTF-8 BOM。
const List<int> _kUtf8Bom = <int>[0xEF, 0xBB, 0xBF];

/// 文件的文本形态：正文，加上写回时要还原的两个细节。
class TextFileShape {
  const TextFileShape({
    required this.content,
    required this.hadBom,
    required this.newline,
  });

  /// 已剥掉 BOM、行尾统一成 `\n` 的正文。
  ///
  /// 统一之后模型给的 `find` 才可能匹配上：它写的多行文本一定用 `\n`，
  /// 而 Windows 上的文件是 `\r\n`——不统一就永远匹配不到，然后按"匹配不到
  /// 就报错绝不猜"的规矩报错，用户看到的是 `edit_file` 在 Windows 上全废。
  final String content;

  final bool hadBom;

  /// 原文件的行尾，`\r\n` 或 `\n`。
  final String newline;

  /// 把正文还原成原文件的形态。
  ///
  /// 还原而不是统一成 `\n`：改一行不该顺手把整个文件的行尾换掉——那会让
  /// 版本控制显示"整个文件都变了"，也可能弄坏依赖 CRLF 的下游工具。
  List<int> encode(String text) {
    final String restored =
        newline == '\n' ? text : text.replaceAll('\n', newline);
    final List<int> body = utf8.encode(restored);
    return hadBom ? <int>[..._kUtf8Bom, ...body] : body;
  }
}

/// 剥掉开头的 UTF-8 BOM。没有就原样返回。
List<int> stripBom(List<int> bytes) {
  if (bytes.length < 3) return bytes;
  if (bytes[0] != _kUtf8Bom[0] ||
      bytes[1] != _kUtf8Bom[1] ||
      bytes[2] != _kUtf8Bom[2]) {
    return bytes;
  }
  return bytes.sublist(3);
}

bool hasBom(List<int> bytes) => bytes.length != stripBom(bytes).length;

/// 内容看起来是二进制。
///
/// 只看前 8 KB 里有没有 NUL 字节。不做更聪明的判断（统计不可打印字符
/// 比例之类）：那种启发式会把某些合法的 UTF-8 文本判成二进制，而"读不了
/// 一个明明是文本的文件"比"试着读了一个二进制文件然后 UTF-8 解码失败"
/// 更难排查。
bool looksBinary(List<int> bytes) {
  final int limit = bytes.length < 8192 ? bytes.length : 8192;
  for (int i = 0; i < limit; i++) {
    if (bytes[i] == 0) return true;
  }
  return false;
}

/// 探测行尾。
///
/// 只要出现过 `\r\n` 就算 CRLF 文件：混合行尾的文件按 CRLF 还原，比按 LF
/// 还原少改动几行。文件里一个换行都没有时跟随平台默认。
String detectNewline(String text) {
  if (text.contains('\r\n')) return '\r\n';
  if (text.contains('\n')) return '\n';
  return Platform.isWindows ? '\r\n' : '\n';
}

/// 读一个文本文件，同时记下 BOM 和行尾。
///
/// 抛 [FormatException]（不是 UTF-8）或 [FileSystemException]（读不到），
/// 调用方负责翻成 `ToolResult.error`——它知道该跟模型怎么说。
TextFileShape readTextFile(File file) {
  final List<int> bytes = file.readAsBytesSync();
  final String raw = utf8.decode(stripBom(bytes));
  return TextFileShape(
    content: raw.replaceAll('\r\n', '\n'),
    hadBom: hasBom(bytes),
    newline: detectNewline(raw),
  );
}
