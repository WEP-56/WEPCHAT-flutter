import 'package:flutter/material.dart';

import '../../theme/palette.dart';

class SegOption<T> {
  const SegOption(this.value, this.label);

  final T value;
  final String label;
}

/// 分段选择器。设置页的「禁止 / 询问 / 允许」等三档开关统一用它，
/// 避免每处各写一套按钮组。
class SegmentedControl<T> extends StatelessWidget {
  const SegmentedControl({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
    this.small = false,
    this.expand = false,
  });

  final List<SegOption<T>> options;
  final T value;
  final ValueChanged<T> onChanged;
  final bool small;

  /// true 时每段等宽铺满可用宽度（移动端设置页需要）。
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final double height = small ? 24 : 28;

    final List<Widget> segments = options.map((SegOption<T> option) {
      final bool selected = option.value == value;
      final Widget segment = InkWell(
        onTap: selected ? null : () => onChanged(option.value),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: height,
          alignment: Alignment.center,
          padding: EdgeInsets.symmetric(horizontal: small ? 8 : 11),
          decoration: BoxDecoration(
            color: selected ? palette.bg : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: selected ? Border.all(color: palette.border) : null,
          ),
          child: Text(
            option.label,
            style: TextStyle(
              fontSize: small ? 10.5 : 11.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
              color: selected ? palette.text1 : palette.text3,
            ),
          ),
        ),
      );
      return expand ? Expanded(child: segment) : segment;
    }).toList();

    return Container(
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
        children: segments,
      ),
    );
  }
}

/// 开关。尺寸比 Material Switch 小，和整体密度一致。
class AppSwitch extends StatelessWidget {
  const AppSwitch({super.key, required this.value, required this.onChanged});

  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(12),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        width: 36,
        height: 20,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: value ? palette.accent : palette.bgRaise2,
          borderRadius: BorderRadius.circular(12),
        ),
        child: AnimatedAlign(
          duration: const Duration(milliseconds: 140),
          alignment: value ? Alignment.centerRight : Alignment.centerLeft,
          child: Container(
            width: 16,
            height: 16,
            decoration: const BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
            ),
          ),
        ),
      ),
    );
  }
}
