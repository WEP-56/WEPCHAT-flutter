/// 用量条：显示最近一轮的 token 消耗（实施 TODO §10-5、§6-12）。
library;

import 'package:flutter/material.dart';

import '../../ai/messages.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';

/// 输入框上方的一行用量。
///
/// `cacheRead` 单独显示且排在前面：缓存有没有命中是 §6 那一整节工作的
/// 唯一验证手段，混在总量里就看不出来了。没有用量数据时整行不占位——
/// 一行"0 tokens"对用户没有信息量。
class UsageBar extends StatelessWidget {
  const UsageBar({super.key, required this.usage});

  final TokenUsage? usage;

  @override
  Widget build(BuildContext context) {
    final TokenUsage? u = usage;
    if (u == null || u.isEmpty) return const SizedBox.shrink();

    final AppPalette palette = context.palette;
    final List<String> parts = <String>[
      '↑ ${_n(u.inputTokens)}',
      '↓ ${_n(u.outputTokens)}',
      if (u.cacheReadTokens > 0) '缓存命中 ${_n(u.cacheReadTokens)}',
      if (u.cacheWriteTokens > 0) '缓存写入 ${_n(u.cacheWriteTokens)}',
      if (u.reasoningTokens > 0) '思考 ${_n(u.reasoningTokens)}',
    ];

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: <Widget>[
          Text(
            '本轮 ${parts.join(' · ')}',
            style: AppFonts.mono(size: 10, color: palette.text3),
          ),
        ],
      ),
    );
  }

  /// 四位以上加千分位。token 数经常上万，`12345` 一眼读不出量级。
  static String _n(int value) {
    if (value < 1000) return '$value';
    final String digits = value.toString();
    final StringBuffer buf = StringBuffer();
    for (int i = 0; i < digits.length; i++) {
      if (i > 0 && (digits.length - i) % 3 == 0) buf.write(',');
      buf.write(digits[i]);
    }
    return buf.toString();
  }
}
