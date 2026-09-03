import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/workspace.dart';
import '../../../platform/workspace_picker.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../settings_card.dart';

/// 工作区根目录。每个会话在其下有自己的目录，目录名是稳定的 session_id
/// （功能协议 §2.1）。
class WorkspaceSection extends StatelessWidget {
  const WorkspaceSection({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    final String sessionId = context.sessions.active.id;

    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final AppPalette palette = context.palette;
        return SettingsCard(
          title: '工作区',
          subtitle: '会话目录名使用不会变化的 session_id，重命名会话不会移动文件。',
          children: <Widget>[
            if (supportsWorkspaceRootSelection)
              SettingsRow(
                title: '根目录',
                trailing: OutlinedButton.icon(
                  onPressed: () => unawaited(_edit(context, settings)),
                  icon: const Icon(Icons.folder_outlined, size: 15),
                  label: const Text('选择目录'),
                ),
              ),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              decoration: BoxDecoration(
                color: palette.bgRaise,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    settings.workspaceRoot,
                    style: AppFonts.mono(size: 11, color: palette.text1),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '当前会话：${sessionWorkspacePath(settings.workspaceRoot, sessionId)}',
                    style: AppFonts.mono(size: 10.5, color: palette.text3),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _edit(BuildContext context, AppSettings settings) async {
    final String? path = await pickWorkspaceRoot(settings.workspaceRoot);
    if (path == null || path.trim().isEmpty || !context.mounted) return;
    settings.setWorkspaceRoot(path);
  }
}
