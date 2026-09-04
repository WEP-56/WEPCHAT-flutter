import 'dart:async';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../backup/webdav_backup.dart';
import '../../../state/app_scope.dart';
import '../../../theme/palette.dart';
import '../settings_card.dart';

class StorageBackupSection extends StatefulWidget {
  const StorageBackupSection({super.key});
  @override
  State<StorageBackupSection> createState() => _StorageBackupSectionState();
}

class _StorageBackupSectionState extends State<StorageBackupSection> {
  WebDavConfig? _config;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final p = await SharedPreferences.getInstance();
    final url = p.getString('webdav.url');
    if (!mounted || url == null || url.isEmpty) return;
    setState(
      () => _config = WebDavConfig(
        url: url,
        username: p.getString('webdav.user') ?? '',
        password: p.getString('webdav.pass') ?? '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.palette;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsCard(
          title: '存储与备份',
          subtitle: '本地数据与 WebDAV 手动备份。偏好设置不会包含在备份中。',
          children: [
            SettingsRow(
              title: 'WebDAV',
              trailing: OutlinedButton.icon(
                onPressed: () => unawaited(_edit()),
                icon: const Icon(Icons.cloud_outlined, size: 16),
                label: Text(_config == null ? '添加' : '编辑'),
              ),
            ),
            if (_config != null) ...[
              Text(
                _config!.url,
                style: TextStyle(fontSize: 11, color: palette.text3),
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => unawaited(_backup()),
                    icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: const Text('备份'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_restore()),
                    icon: const Icon(Icons.cloud_download_outlined, size: 16),
                    label: const Text('恢复'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 8),
            Text(
              '备份为未加密的 ZIP（扩展名 .wepchat），包含对话、长期记忆、模型与搜索提供商配置。请谨慎保存并选择可信的 WebDAV 服务商。',
              style: TextStyle(fontSize: 11, color: palette.text3, height: 1.4),
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _edit() async {
    final result = await showDialog<WebDavConfig>(
      context: context,
      builder: (_) => _WebDavDialog(initial: _config),
    );
    if (result == null) return;
    final p = await SharedPreferences.getInstance();
    await p.setString('webdav.url', result.url);
    await p.setString('webdav.user', result.username);
    await p.setString('webdav.pass', result.password);
    if (mounted) setState(() => _config = result);
  }

  Future<void> _backup() async {
    final config = _config;
    if (config == null) return;
    setState(() => _busy = true);
    final service = WebDavBackupService();
    try {
      final bytes = await service.buildBackup(
        settings: context.settings,
        storage: context.sessions.storage,
      );
      await service.upload(config, bytes);
      if (mounted) _snack('备份已上传');
    } catch (e) {
      if (mounted) _snack('备份失败：$e');
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _restore() async {
    final config = _config;
    if (config == null) return;
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('恢复 WebDAV 备份？'),
        content: const Text('将导入备份中的会话、记忆和提供商配置；现有数据不会自动删除。请确认备份来自可信来源。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('继续')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final service = WebDavBackupService();
    try {
      await service.restore(
        config: config,
        settings: context.settings,
        storage: context.sessions.storage,
      );
      if (mounted) _snack('恢复完成；请重启应用以刷新会话列表（偏好设置保持不变）');
    } catch (e) {
      if (mounted) _snack('恢复失败：$e');
    } finally {
      service.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String text) => ScaffoldMessenger.of(context)
    ..clearSnackBars()
    ..showSnackBar(SnackBar(content: Text(text)));
}

class _WebDavDialog extends StatefulWidget {
  const _WebDavDialog({this.initial});
  final WebDavConfig? initial;
  @override
  State<_WebDavDialog> createState() => _WebDavDialogState();
}

class _WebDavDialogState extends State<_WebDavDialog> {
  late final _url = TextEditingController(text: widget.initial?.url ?? '');
  late final _user = TextEditingController(
    text: widget.initial?.username ?? '',
  );
  late final _pass = TextEditingController(
    text: widget.initial?.password ?? '',
  );
  bool _testing = false;
  @override
  void dispose() {
    _url.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('WebDAV 设置'),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: '地址（目录 URL）',
              hintText: 'https://dav.example.com/backups/',
            ),
          ),
          TextField(
            controller: _user,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          TextField(
            controller: _pass,
            obscureText: true,
            decoration: const InputDecoration(labelText: '密码 / 应用专用密码'),
          ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _testing
            ? null
            : () async {
                final uri = Uri.tryParse(_url.text.trim());
                if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
                setState(() => _testing = true);
                final service = WebDavBackupService();
                try {
                  await service.test(WebDavConfig(url: _url.text.trim(), username: _user.text.trim(), password: _pass.text));
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('WebDAV 连接成功')));
                } catch (e) {
                  if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('连接失败：$e')));
                } finally {
                  service.close();
                  if (mounted) setState(() => _testing = false);
                }
              },
        child: const Text('测试连接'),
      ),
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          final url = _url.text.trim();
          final uri = Uri.tryParse(url);
          if (uri == null ||
              !uri.hasScheme ||
              (uri.scheme != 'http' && uri.scheme != 'https'))
            return;
          Navigator.pop(
            context,
            WebDavConfig(
              url: url,
              username: _user.text.trim(),
              password: _pass.text,
            ),
          );
        },
        child: const Text('保存'),
      ),
    ],
  );
}
