import 'dart:async';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../../app/update_service.dart';
import '../../../browser/browser_launcher.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/palette.dart';
import '../../update_dialog.dart';
import '../settings_card.dart';

class AboutSection extends StatefulWidget {
  const AboutSection({super.key});

  @override
  State<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends State<AboutSection> {
  late final Future<PackageInfo> _packageInfo = PackageInfo.fromPlatform();
  bool _checking = false;

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return SettingsCard(
      title: '关于',
      subtitle: 'WePChat 是一个开源的轻量 LLM 聊天客户端。',
      children: <Widget>[
        Center(
          child: Image.asset(
            'assets/logo.png',
            width: 112,
            height: 112,
            fit: BoxFit.contain,
            errorBuilder: (_, Object error, StackTrace? stack) =>
                const Icon(Icons.image_not_supported_outlined, size: 64),
          ),
        ),
        const SizedBox(height: 4),
        FutureBuilder<PackageInfo>(
          future: _packageInfo,
          builder: (BuildContext context, AsyncSnapshot<PackageInfo> snapshot) {
            final String version = snapshot.hasData
                ? 'v${snapshot.data!.version}'
                : '读取版本中…';
            return Center(
              child: Text(
                version,
                style: TextStyle(fontSize: 11, color: context.palette.text3),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        _LinkRow(
          icon: Icons.code,
          title: '开源仓库',
          subtitle: kRepositoryUrl,
          onTap: () => openWebUrl(context, kRepositoryUrl),
        ),
        _LinkRow(
          icon: Icons.bug_report_outlined,
          title: '发现问题',
          subtitle: kIssuesUrl,
          onTap: () => openWebUrl(context, kIssuesUrl),
        ),
        _LinkRow(
          icon: Icons.description_outlined,
          title: '开源协议',
          subtitle: 'MIT License',
          onTap: () => openWebUrl(context, '$kRepositoryUrl/blob/main/LICENSE'),
        ),
        SettingsRow(
          title: '检查更新',
          desc: '从 GitHub Releases 检查最新版本。',
          trailing: OutlinedButton(
            onPressed: _checking ? null : () => unawaited(_checkUpdate()),
            child: Text(_checking ? '检查中…' : '检查更新'),
          ),
        ),
        SettingsRow(
          title: '自动检查更新',
          desc: '每次启动时静默检查；发现新版本时显示更新提示。',
          trailing: Switch(
            value: settings.autoCheckUpdates,
            onChanged: settings.setAutoCheckUpdates,
          ),
        ),
      ],
    );
  }

  Future<void> _checkUpdate() async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final PackageInfo info = await _packageInfo;
      final UpdateService service = UpdateService();
      final UpdateCheckResult result;
      try {
        result = await service.check(info.version);
      } finally {
        service.dispose();
      }

      if (!mounted) return;
      if (result.hasUpdate) {
        await showReleaseUpdateDialog(context, result.release!);
      } else if (result.error != null) {
        _showMessage(result.error!);
      } else {
        _showMessage('当前已是最新版本');
      }
    } on Object catch (e) {
      if (mounted) _showMessage('读取当前版本失败：$e');
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  void _showMessage(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }
}

class _LinkRow extends StatelessWidget {
  const _LinkRow({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 4),
        child: Row(
          children: <Widget>[
            Icon(icon, size: 17, color: palette.text2),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    title,
                    style: TextStyle(fontSize: 12.5, color: palette.text1),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 10.5, color: palette.text3),
                  ),
                ],
              ),
            ),
            Icon(Icons.open_in_new, size: 14, color: palette.text3),
          ],
        ),
      ),
    );
  }
}
