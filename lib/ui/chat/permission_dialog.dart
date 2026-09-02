/// 工具执行确认弹窗（实施 TODO §7-11，功能协议 §9）。
library;

import 'package:flutter/material.dart';

import '../../models/settings.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../../tools/permission_gate.dart';
import '../../tools/tool_summary.dart';
import '../settings/dialog_bits.dart';

/// 弹出确认框，等用户选择。
///
/// 三个出口都返回一个明确的答案，**不返回 null 表示"关掉了"**：点遮罩关掉
/// 弹窗和点「拒绝」是同一个意思，而权限门看到 null 也按拒绝处理——这里统一
/// 成拒绝，是为了让"用户没表态"不可能被读成放行。
Future<PermissionAnswer?> showPermissionDialog(
  BuildContext context,
  PermissionRequest request,
) {
  return showDialog<PermissionAnswer>(
    context: context,
    barrierDismissible: true,
    builder: (BuildContext context) => _PermissionDialog(request: request),
  ).then(
    (PermissionAnswer? answer) => answer ?? const PermissionAnswer.reject(),
  );
}

class _PermissionDialog extends StatelessWidget {
  const _PermissionDialog({required this.request});

  final PermissionRequest request;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final ToolPermissionSpec? spec = _specOf(request.permissionId);

    return AlertDialog(
      icon: Icon(
        spec?.icon ?? Icons.help_outline,
        size: 22,
        color: palette.accent,
      ),
      title: Text(
        '允许「${spec?.name ?? request.toolName}」吗？',
        style: const TextStyle(fontSize: 15.5),
      ),
      content: SizedBox(
        width: dialogWidth(context),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              '模型请求执行 ${request.toolName}。',
              style: TextStyle(fontSize: 12.5, color: palette.text2),
            ),
            const SizedBox(height: 10),
            // 参数原样给用户看：确认的是"这次这些参数"，只说工具名等于让人
            // 盲签。摘要和事后工具卡片上显示的是同一句（`tool_summary.dart`），
            // 用户才能回头核对自己批准了什么。
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: palette.bgRaise,
                borderRadius: BorderRadius.circular(8),
              ),
              child: SelectableText(
                summarizeToolArguments(request.arguments, valueLimit: 200),
                style: AppFonts.mono(
                  size: 11.5,
                  color: palette.text2,
                  height: 1.5,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              '「本会话一直允许」只在这个会话里生效，重启后失效。'
              '要永久改变，去设置页的工具权限。',
              style: TextStyle(fontSize: 10.5, color: palette.text3),
            ),
          ],
        ),
      ),
      actionsOverflowButtonSpacing: 6,
      actions: <Widget>[
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const PermissionAnswer.reject()),
          child: const Text('拒绝'),
        ),
        TextButton(
          onPressed: () =>
              Navigator.of(context).pop(const PermissionAnswer.allowAlways()),
          child: const Text('本会话一直允许'),
        ),
        FilledButton(
          onPressed: () =>
              Navigator.of(context).pop(const PermissionAnswer.allowOnce()),
          child: const Text('允许一次'),
        ),
      ],
    );
  }

  static ToolPermissionSpec? _specOf(String id) {
    for (final ToolPermissionSpec spec in kToolPermissionSpecs) {
      if (spec.id == id) return spec;
    }
    return null;
  }
}
