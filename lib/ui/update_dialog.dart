import 'package:flutter/material.dart';

import '../app/update_service.dart';
import '../browser/browser_launcher.dart';
import '../theme/palette.dart';

Future<void> showReleaseUpdateDialog(
  BuildContext context,
  ReleaseInfo release,
) async {
  await showDialog<void>(
    context: context,
    builder: (BuildContext dialogContext) {
      final AppPalette palette = context.palette;
      return AlertDialog(
        title: const Text('发现新版本'),
        content: Text(
          '${release.name}\n最新版本：${release.version}',
          style: TextStyle(color: palette.text2, height: 1.5),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('稍后'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(dialogContext).pop();
              openWebUrl(context, release.url);
            },
            child: const Text('前往更新'),
          ),
        ],
      );
    },
  );
}
