import 'package:flutter/material.dart';

/// 轻量提示。纯前端阶段大量“预览”动作用它给出反馈。
void showAppToast(BuildContext context, String message) {
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.clearSnackBars();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message),
      duration: const Duration(milliseconds: 1800),
      width: 320,
    ),
  );
}
