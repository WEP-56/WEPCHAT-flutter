import 'package:flutter/material.dart';

import '../../../browser/browser_downloads.dart';
import '../../../browser/browser_history.dart';
import '../../../browser/browser_page.dart';
import '../../../platform/open_file.dart';
import '../../widgets/toast.dart';
import '../settings_card.dart';

class BrowserSection extends StatefulWidget {
  const BrowserSection({super.key});

  @override
  State<BrowserSection> createState() => _BrowserSectionState();
}

class _BrowserSectionState extends State<BrowserSection> {
  final BrowserHistoryStore _history = BrowserHistoryStore.instance;
  final BrowserDownloadStore _downloads = BrowserDownloadStore.instance;
  final TextEditingController _urlController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _history.addListener(_changed);
    _downloads.addListener(_changed);
    _history.ensureLoaded();
    _downloads.ensureLoaded();
  }

  @override
  void dispose() {
    _urlController.dispose();
    _history.removeListener(_changed);
    _downloads.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return SettingsCard(
      title: '应用内浏览器（Android）',
      subtitle: 'Windows 始终使用系统默认浏览器。',
      children: <Widget>[
        SettingsRow(
          title: '快捷访问',
          desc: '输入网址后在应用内浏览器打开，可用于快速访问或测试。',
          trailing: SizedBox(
            width: 330,
            child: TextField(
              controller: _urlController,
              keyboardType: TextInputType.url,
              textInputAction: TextInputAction.go,
              onSubmitted: (_) => _openUrl(),
              decoration: InputDecoration(
                hintText: 'example.com 或 https://example.com',
                isDense: true,
                suffixIcon: IconButton(
                  tooltip: '打开',
                  onPressed: _openUrl,
                  icon: const Icon(Icons.arrow_forward_rounded, size: 18),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 4),
        SettingsRow(
          title: '浏览历史',
          trailing: Wrap(
            spacing: 6,
            children: <Widget>[
              OutlinedButton(
                onPressed: () => _showHistory(context),
                child: Text('查看 (${_history.items.length})'),
              ),
              OutlinedButton(
                onPressed: _history.items.isEmpty ? null : _history.clear,
                child: const Text('清理'),
              ),
            ],
          ),
        ),
        SettingsRow(
          title: '下载管理',
          trailing: Wrap(
            spacing: 6,
            children: <Widget>[
              OutlinedButton(
                onPressed: () => _showDownloads(context),
                child: Text('查看 (${_downloads.items.length})'),
              ),
              OutlinedButton(
                onPressed: _downloads.items.isEmpty ? null : _downloads.clear,
                child: const Text('清理'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _openUrl() {
    String value = _urlController.text.trim();
    if (value.isEmpty) return;
    if (!value.startsWith('http://') && !value.startsWith('https://')) {
      value = 'https://$value';
    }
    final Uri? uri = Uri.tryParse(value);
    if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https') || uri.host.isEmpty) {
      showAppToast(context, '请输入有效的网址');
      return;
    }
    FocusScope.of(context).unfocus();
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BrowserPage(url: uri.toString())));
  }

  Future<void> _showHistory(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('浏览历史'),
        content: SizedBox(width: 560, child: _historyList(context)),
      ),
    );
  }

  Future<void> _showDownloads(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('下载管理'),
        content: SizedBox(width: 560, child: _downloadList(context)),
      ),
    );
  }

  Widget _historyList(BuildContext dialogContext) {
    if (_history.items.isEmpty) {
      return const _BrowserEmptyState(icon: Icons.history, message: '暂无浏览记录');
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .62),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _history.items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, index) {
          final item = _history.items[index];
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.language, size: 18)),
              title: Text(item.title.isEmpty ? item.url : item.title, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${item.url}\n${_formatDate(item.visitedAt)}', maxLines: 2, overflow: TextOverflow.ellipsis),
              isThreeLine: true,
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.pop(dialogContext);
                Navigator.push(dialogContext, MaterialPageRoute<void>(builder: (_) => BrowserPage(url: item.url)));
              },
            ),
          );
        },
      ),
    );
  }

  Widget _downloadList(BuildContext dialogContext) {
    if (_downloads.items.isEmpty) {
      return const _BrowserEmptyState(icon: Icons.download_outlined, message: '暂无下载记录');
    }
    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * .62),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: _downloads.items.length,
        separatorBuilder: (_, __) => const SizedBox(height: 6),
        itemBuilder: (_, index) {
          final item = _downloads.items[index];
          final bool done = item.status == 'done';
          final bool running = item.status == 'downloading';
          final IconData icon = running ? Icons.downloading : done ? Icons.check_circle_outline : Icons.error_outline;
          final Color color = running ? Colors.blue : done ? Colors.green : Theme.of(context).colorScheme.error;
          return Card(
            margin: EdgeInsets.zero,
            child: ListTile(
              leading: Icon(icon, color: color),
              title: Text(item.filename, maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text('${running ? '下载中' : done ? '已完成' : '下载失败'}${item.path == null ? '' : '\n${item.path}'}', maxLines: 2, overflow: TextOverflow.ellipsis),
              isThreeLine: item.path != null,
              trailing: done && item.path != null ? const Icon(Icons.open_in_new, size: 19) : null,
              onTap: done && item.path != null
                  ? () async {
                      final ok = await openFileInDefaultApp(item.path!);
                      if (!ok && dialogContext.mounted) showAppToast(dialogContext, '无法打开文件，请检查是否安装对应应用');
                    }
                  : null,
            ),
          );
        },
      ),
    );
  }

  String _formatDate(DateTime date) {
    final DateTime local = date.toLocal();
    return '${local.year}/${local.month.toString().padLeft(2, '0')}/${local.day.toString().padLeft(2, '0')} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}

class _BrowserEmptyState extends StatelessWidget {
  const _BrowserEmptyState({required this.icon, required this.message});
  final IconData icon;
  final String message;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 36),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Icon(icon, size: 42, color: Theme.of(context).colorScheme.outline),
      const SizedBox(height: 10),
      Text(message, style: TextStyle(color: Theme.of(context).colorScheme.outline)),
    ]),
  );
}
