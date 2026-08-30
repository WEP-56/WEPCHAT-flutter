import 'package:flutter/material.dart';

import '../../theme/palette.dart';
import 'segmented_control.dart';

/// 下拉选择器。视觉与 [SegmentedControl] 一致，用于选项较多的设置项。
class MenuPicker<T> extends StatelessWidget {
  const MenuPicker({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.tooltip,
  });

  final T value;
  final List<SegOption<T>> options;
  final ValueChanged<T> onChanged;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final SegOption<T> current = options.firstWhere(
      (SegOption<T> option) => option.value == value,
      orElse: () => throw ArgumentError.value(value, 'value', '不在 options 中'),
    );

    return PopupMenuButton<T>(
      tooltip: tooltip,
      position: PopupMenuPosition.under,
      onSelected: onChanged,
      itemBuilder: (BuildContext _) {
        return options.map((SegOption<T> option) {
          return PopupMenuItem<T>(
            value: option.value,
            height: 38,
            child: Row(
              children: <Widget>[
                Icon(
                  option.value == value
                      ? Icons.radio_button_checked
                      : Icons.radio_button_unchecked,
                  size: 14,
                  color: option.value == value ? palette.accent : palette.text3,
                ),
                const SizedBox(width: 8),
                Text(option.label, style: const TextStyle(fontSize: 12.5)),
              ],
            ),
          );
        }).toList();
      },
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 9),
        decoration: BoxDecoration(
          color: palette.bgRaise,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              current.label,
              style: TextStyle(
                fontSize: 11.5,
                fontWeight: FontWeight.w500,
                color: palette.text1,
              ),
            ),
            const SizedBox(width: 3),
            Icon(Icons.expand_more, size: 15, color: palette.text3),
          ],
        ),
      ),
    );
  }
}
