/// 消息底部的操作栏（用量 + 按钮）。
///
/// 用量从底部的 `UsageBar` 挪到这里：那条只显示"最近一轮"，翻回去看历史
/// 消息时对不上；挂在消息上则每条各自带着自己的数字。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../models/chat.dart';
import '../../theme/palette.dart';
import '../widgets/toast.dart';

/// 悬停时才显示的一行操作。
///
/// 桌面端跟随鼠标悬停淡入淡出，触摸端（没有悬停概念）常驻显示——
/// 手机上没有"把鼠标移上去"这个动作，藏起来等于没有。
///
/// 悬停由 [hovered] 从外面传进来而不是自己监听：只监听这一行的话，隐着的
/// 时候用户不知道那儿有东西，得盲摸才找得到按钮。
class MessageActionBar extends StatelessWidget {
  const MessageActionBar({
    super.key,
    required this.message,
    required this.alignEnd,
    this.hovered = false,
    this.onRegenerate,
    this.onEdit,
  });

  final ChatMessage message;

  /// 用户消息靠右，助手消息靠左。
  final bool alignEnd;

  /// 鼠标是否停在整条消息上。
  final bool hovered;

  final VoidCallback? onRegenerate;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    // 触摸端一律显示。`Theme.platform` 而不是 `Platform.isAndroid`：测试里
    // 要能改，桌面上也有触摸屏的将来。
    final bool touch = switch (Theme.of(context).platform) {
      TargetPlatform.android || TargetPlatform.iOS => true,
      _ => false,
    };
    final bool visible = touch || hovered;
    final AppPalette palette = context.palette;
    final MessageUsage? usage = message.usage;

    return AnimatedOpacity(
      opacity: visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      // 透明时挡住点击：淡出那 120ms 里按钮还在原地，误点一下重新回答是
      // 要花钱的。占位不撤——按钮一出现就把下文顶开会更难点中。
      child: IgnorePointer(
        ignoring: !visible,
        child: Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(
            alignment: alignEnd ? WrapAlignment.end : WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 2,
            runSpacing: 2,
            children: <Widget>[
              if (usage != null && !usage.isEmpty) ...<Widget>[
                _Stat(
                  icon: Icons.arrow_upward,
                  value: _n(usage.inputTokens),
                  tooltip: '输入 token',
                ),
                if (usage.cacheReadTokens > 0)
                  _Stat(
                    icon: Icons.bolt_outlined,
                    value: _n(usage.cacheReadTokens),
                    tooltip: '缓存命中 token',
                  ),
                if (usage.cacheWriteTokens > 0)
                  _Stat(
                    icon: Icons.save_outlined,
                    value: _n(usage.cacheWriteTokens),
                    tooltip: '缓存写入 token',
                  ),
                if (usage.reasoningTokens > 0)
                  _Stat(
                    icon: Icons.psychology_alt_outlined,
                    value: _n(usage.reasoningTokens),
                    tooltip: '思考 token',
                  ),
                _Stat(
                  icon: Icons.arrow_downward,
                  value: _n(usage.outputTokens),
                  tooltip: '输出 token',
                ),
              ],
              if (message.elapsed != null)
                _Stat(
                  icon: Icons.schedule,
                  value:
                      '${(message.elapsed!.inMilliseconds / 1000).toStringAsFixed(1)}s',
                  tooltip: '耗时',
                ),
              _MiniAction(
                icon: Icons.content_copy_outlined,
                tooltip: '复制',
                onTap: () => _copy(context, message.rawText),
              ),
              if (onEdit != null)
                _MiniAction(
                  icon: Icons.edit_outlined,
                  tooltip: '编辑并重发',
                  onTap: onEdit!,
                ),
              if (onRegenerate != null)
                _MiniAction(
                  icon: Icons.refresh,
                  tooltip: message.isUser ? '重新生成' : '重新回答',
                  onTap: onRegenerate!,
                ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: Text(
                  message.time,
                  style: TextStyle(fontSize: 10, color: palette.text3),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _copy(BuildContext context, String text) async {
    await Clipboard.setData(ClipboardData(text: text));
    if (!context.mounted) return;
    showAppToast(context, '已复制');
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

/// 一项统计（图标 + 数字）。
class _Stat extends StatelessWidget {
  const _Stat({required this.icon, required this.value, required this.tooltip});

  final IconData icon;
  final String value;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 11, color: palette.text3),
            const SizedBox(width: 3),
            Text(value, style: TextStyle(fontSize: 10.5, color: palette.text3)),
          ],
        ),
      ),
    );
  }
}

/// 操作栏上的小图标按钮。比 `IconAction` 更紧凑。
class _MiniAction extends StatelessWidget {
  const _MiniAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: palette.hover,
        child: SizedBox(
          width: 26,
          height: 24,
          child: Center(child: Icon(icon, size: 13, color: palette.text3)),
        ),
      ),
    );
  }
}
