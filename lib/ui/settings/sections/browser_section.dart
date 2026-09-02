import 'package:flutter/material.dart';

import '../../../browser/browser_downloads.dart';
import '../../../browser/browser_history.dart';
import '../settings_card.dart';

class BrowserSection extends StatefulWidget {
  const BrowserSection({super.key});

  @override
  State<BrowserSection> createState() => _BrowserSectionState();
}

class _BrowserSectionState extends State<BrowserSection> {
  final BrowserHistoryStore _history = BrowserHistoryStore.instance;
  final BrowserDownloadStore _downloads = BrowserDownloadStore.instance;

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
          title: '浏览历史',
          trailing: Wrap(
            spacing: 6,
            children: <Widget>[
              OutlinedButton(
                onPressed: _history.items.isEmpty
                    ? null
                    : () => _showHistory(context),
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
                onPressed: _downloads.items.isEmpty
                    ? null
                    : () => _showDownloads(context),
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

  Future<void> _showHistory(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('浏览历史'),
        content: SizedBox(
          width: 520,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _history.items.length,
            itemBuilder: (BuildContext _, int index) {
              final item = _history.items[index];
              return ListTile(
                title: Text(item.title),
                subtitle: Text(
                  item.url,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Future<void> _showDownloads(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('下载管理'),
        content: SizedBox(
          width: 520,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: _downloads.items.length,
            itemBuilder: (BuildContext _, int index) {
              final item = _downloads.items[index];
              return ListTile(
                title: Text(item.filename),
                subtitle: Text(item.status),
              );
            },
          ),
        ),
      ),
    );
  }
}
