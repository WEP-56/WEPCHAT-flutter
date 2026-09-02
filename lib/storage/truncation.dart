/// 截断标记的读取侧语义（存储设计 §8，实施 TODO §9-10）。
///
/// 「改掉上一句重发」在追加式日志里不做成分支树，而是追加一条
/// `type='truncate'` 条目，payload 记下被覆盖的起点 seq。旧条目不删也不改
/// ——条目写入即不可变（存储设计 §7.1）。
///
/// 所以每个读取侧都必须自己跳过被覆盖的区间。放在这里而不是各处重写一遍：
/// 上下文组装和界面展示要跳过的是同一批条目，两边算法一旦不一致，用户就会
/// 看到一条已经撤回的消息还在参与提问（`../AGENTS.md` §1.2）。
library;

import 'entry_record.dart';
import 'models.dart';

/// `truncate` 条目 payload 里记录起点的键。
const String kTruncateFromSeq = 'fromSeq';

/// 应用截断标记，返回仍然有效的条目。
///
/// 语义是「一条 `fromSeq = n` 的标记撤回它**之前**所有 `seq >= n` 的条目」。
/// 按顺序边走边删而不是先收集所有标记再一次性过滤，是因为标记之后重新追加
/// 的条目 seq 更大，一次性过滤会把它们也一起吃掉——那正是编辑重发写进来的
/// 新消息。
///
/// 标记本身不出现在结果里：它是元数据，没有可展示或可发送的内容。
List<EntryRecord> applyTruncations(List<EntryRecord> entries) {
  // 绝大多数会话一条标记都没有，先扫一遍避开复制开销。
  if (entries.every((EntryRecord e) => e.type != EntryType.truncate)) {
    return entries;
  }

  final List<EntryRecord> live = <EntryRecord>[];
  for (final EntryRecord entry in entries) {
    if (entry.type == EntryType.truncate) {
      final Object? from = entry.payload[kTruncateFromSeq];
      // 认不出起点的标记按「什么都没撤回」处理：宁可多显示一条，
      // 也不要因为一个坏 payload 把整段历史藏起来。
      if (from is int) {
        live.removeWhere((EntryRecord e) => e.seq >= from);
      }
      continue;
    }
    live.add(entry);
  }
  return live;
}
