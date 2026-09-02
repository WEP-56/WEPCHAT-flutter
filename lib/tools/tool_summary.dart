/// 工具参数摘要（功能协议 §9："工具结果中记录参数摘要"）。
///
/// 权限弹窗和聊天里的工具卡片都要显示"它要拿什么参数干什么"。写成一处
/// 是因为两边显示的必须是同一句话：用户在弹窗里看到的和事后在卡片上看到
/// 的对不上，就没法回头核对自己当时批准了什么（AGENTS.md §1.2）。
library;

/// 把参数拍成一行 `key=value · key=value`。
///
/// 长值会被截短——摘要是给人扫一眼的，不是给人读全文的。真正的完整参数
/// 在工具结果的 `uiPayload` 里。
String summarizeToolArguments(
  Map<String, Object?> arguments, {
  int valueLimit = 60,
}) {
  if (arguments.isEmpty) return '无参数';

  // 按键名排序，让同一个工具的摘要每次长得一样：顺序漂移会让用户以为
  // 参数变了。
  final List<String> keys = arguments.keys.toList()..sort();
  return keys
      .map((String k) => '$k=${_brief(arguments[k], valueLimit)}')
      .join(' · ');
}

String _brief(Object? value, int limit) {
  final String text = switch (value) {
    null => 'null',
    final String s => s,
    final List<Object?> l => '[${l.length} 项]',
    final Map<Object?, Object?> m => '{${m.length} 项}',
    _ => '$value',
  };

  final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (flat.length <= limit) return flat;
  return '${flat.substring(0, limit)}…';
}
