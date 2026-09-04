/// 设置页弹窗里复用的几个小件。
///
/// 提供商与模型两个弹窗都是「一堆带标签的输入框 + 一堆开关」，抽出来是为了
/// 让两边的间距、字号、错误位置一致——不一致的表单看起来比缺功能更像 bug。
library;

import 'package:flutter/material.dart';

import '../../theme/fonts.dart';
import '../../theme/palette.dart';

/// 弹窗宽度。
///
/// 桌面上要「较大」才装得下 baseUrl 这种长字符串；Android 上屏幕就那么宽，
/// 取屏宽减边距，不然弹窗会被 AlertDialog 的 insetPadding 挤成两行标题。
double dialogWidth(BuildContext context) {
  final double screen = MediaQuery.sizeOf(context).width;
  return screen < 560 ? screen - 56 : 460;
}

/// 「标签 + 输入框 + 说明」一组。
class LabeledField extends StatelessWidget {
  const LabeledField({
    super.key,
    required this.label,
    required this.controller,
    this.hint,
    this.helper,
    this.error,
    this.obscure = false,
    this.mono = false,
    this.numeric = false,
    this.autofocus = false,
    this.onChanged,
    this.onSubmitted,
  });

  final String label;
  final TextEditingController controller;
  final String? hint;
  final String? helper;

  /// 校验错误。非空时输入框描红并在下方显示，替代弹一个 toast——
  /// 错误要出现在出错的那一行旁边。
  final String? error;

  final bool obscure;
  final bool mono;
  final bool numeric;
  final bool autofocus;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: palette.text2,
            ),
          ),
          const SizedBox(height: 5),
          TextField(
            controller: controller,
            autofocus: autofocus,
            obscureText: obscure,
            keyboardType: numeric ? TextInputType.number : null,
            style: mono
                ? AppFonts.mono(size: 12.5, color: palette.text1)
                : TextStyle(fontSize: 13, color: palette.text1),
            decoration: InputDecoration(
              isDense: true,
              hintText: hint,
              hintStyle: TextStyle(fontSize: 12.5, color: palette.text3),
              errorText: error,
              helperText: helper,
              helperMaxLines: 3,
              helperStyle: TextStyle(fontSize: 10.5, color: palette.text3),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: const OutlineInputBorder(),
            ),
            onChanged: onChanged,
            onSubmitted: onSubmitted,
          ),
        ],
      ),
    );
  }
}

/// 「标签 + 说明 + 开关」一行。模型元数据里九个标记都是这个形状。
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.desc,
  });

  final String label;
  final String? desc;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  label,
                  style: TextStyle(fontSize: 12.5, color: palette.text1),
                ),
                if (desc != null)
                  Text(
                    desc!,
                    style: TextStyle(fontSize: 10.5, color: palette.text3),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }
}

/// 弹窗里的分组小标题。
class DialogGroupLabel extends StatelessWidget {
  const DialogGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 6, bottom: 6),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.3,
          color: context.palette.text3,
        ),
      ),
    );
  }
}
