/// 回传给模型的文本截断（实施 TODO §7-6）。
///
/// **只有这一个实现**：每个工具各写一遍会长出各自的上限和各自的提示语，
/// 而模型靠提示语判断"是不是还有后文"——措辞不一致它就判断不准
/// （AGENTS.md §1.2）。
library;

/// 单个工具结果回传给模型的字符上限。
///
/// 这是"进上下文的量"，和 `kMaxReadBytes`（一次读盘的量）不是一回事：
/// 后者防的是把大文件整个读进内存，前者防的是把上下文一次撑爆。
const int kMaxToolResultChars = 24000;

/// 超长就截断，并在末尾说明截了多少。
///
/// 提示写成模型能据此行动的话：它看到"还有 N 字符"才知道要用 `lines`
/// 分段读，而不是以为文件就这么长。
String truncateForModel(String text, {int limit = kMaxToolResultChars}) {
  if (text.length <= limit) return text;
  final int dropped = text.length - limit;
  return '${text.substring(0, limit)}\n\n'
      '[已截断：还有 $dropped 个字符未显示，原始长度 ${text.length}。'
      '需要后续内容请指定范围再读一次]';
}
