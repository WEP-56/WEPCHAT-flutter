// ignore_for_file: curly_braces_in_flow_control_structures, deprecated_member_use
import 'dart:async';
import 'package:flutter/material.dart';
import '../../../models/settings.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/fonts.dart';
import '../../../theme/palette.dart';
import '../../widgets/controls.dart';
import '../dialog_bits.dart';
import '../settings_card.dart';

class SearchSection extends StatelessWidget {
  const SearchSection({super.key});
  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) => SettingsCard(
        title: '网页搜索',
        subtitle: '可配置 Tavily、Exa、Serper 或自建 SearXNG；搜索 Key 与聊天模型完全独立。',
        children: <Widget>[
          for (final SearchProviderConfig provider in settings.searchProviders)
            _SearchProviderRow(
              provider: provider,
              selected: provider.id == settings.searchBackendId,
            ),
          const SizedBox(height: 6),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => unawaited(_add(context)),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加搜索服务'),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _add(BuildContext context) async {
    final SearchProviderConfig? value = await showSearchProviderDialog(context);
    if (value != null && context.mounted)
      context.settings.addSearchProvider(value);
  }
}

class _SearchProviderRow extends StatelessWidget {
  const _SearchProviderRow({required this.provider, required this.selected});
  final SearchProviderConfig provider;
  final bool selected;
  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        children: <Widget>[
          IconButton(
            onPressed: () => context.settings.setSearchBackend(provider.id),
            icon: Icon(
              selected
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
              size: 17,
            ),
            color: selected ? palette.accent : palette.text3,
            tooltip: '设为当前搜索服务',
            visualDensity: VisualDensity.compact,
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Flexible(
                      child: Text(
                        provider.name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: palette.text1,
                        ),
                      ),
                    ),
                    const SizedBox(width: 7),
                    Pill(provider.kind, tone: PillTone.accent),
                    const SizedBox(width: 6),
                    provider.configured
                        ? const Pill('已配置', tone: PillTone.good)
                        : const Pill('未配置', tone: PillTone.warn),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  '${provider.maskedKey} · ${provider.baseUrl.isEmpty ? '未填写地址' : provider.baseUrl}',
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.mono(size: 10.5, color: palette.text3),
                ),
              ],
            ),
          ),
          IconAction(
            icon: Icons.tune,
            tooltip: '编辑',
            size: 15,
            box: 28,
            onTap: () => unawaited(_edit(context)),
          ),
          if (!provider.builtin)
            IconAction(
              icon: Icons.delete_outline,
              tooltip: '删除',
              size: 15,
              box: 28,
              tone: IconActionTone.danger,
              onTap: () => context.settings.removeSearchProvider(provider.id),
            ),
        ],
      ),
    );
  }

  Future<void> _edit(BuildContext context) async {
    final SearchProviderConfig? value = await showSearchProviderDialog(
      context,
      existing: provider,
    );
    if (value != null && context.mounted)
      context.settings.updateSearchProvider(value);
  }
}

Future<SearchProviderConfig?> showSearchProviderDialog(
  BuildContext context, {
  SearchProviderConfig? existing,
}) => showDialog<SearchProviderConfig>(
  context: context,
  builder: (BuildContext ctx) => _SearchProviderDialog(existing: existing),
);

class _SearchProviderDialog extends StatefulWidget {
  const _SearchProviderDialog({this.existing});
  final SearchProviderConfig? existing;
  @override
  State<_SearchProviderDialog> createState() => _SearchProviderDialogState();
}

class _SearchProviderDialogState extends State<_SearchProviderDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.name ?? '',
  );
  late final TextEditingController _base = TextEditingController(
    text: widget.existing?.baseUrl ?? '',
  );
  final TextEditingController _key = TextEditingController();
  late String _kind = widget.existing?.kind ?? 'tavily';
  @override
  void dispose() {
    _name.dispose();
    _base.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool edit = widget.existing != null;
    return AlertDialog(
      title: Text(
        edit ? '编辑搜索服务' : '添加搜索服务',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: dialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              LabeledField(
                label: '名称',
                controller: _name,
                hint: '例如 Exa、公司 SearXNG',
                autofocus: !edit,
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _kind,
                decoration: const InputDecoration(
                  labelText: '服务类型',
                  isDense: true,
                ),
                items: const <DropdownMenuItem<String>>[
                  DropdownMenuItem(value: 'tavily', child: Text('Tavily')),
                  DropdownMenuItem(value: 'exa', child: Text('Exa')),
                  DropdownMenuItem(value: 'serper', child: Text('Serper')),
                  DropdownMenuItem(
                    value: 'searxng',
                    child: Text('SearXNG（自建）'),
                  ),
                  DropdownMenuItem(
                    value: 'custom',
                    child: Text('自定义（Tavily 兼容）'),
                  ),
                ],
                onChanged: (String? value) {
                  if (value != null)
                    setState(() {
                      _kind = value;
                      if (_base.text.isEmpty) _base.text = _defaultBase(value);
                    });
                },
              ),
              const SizedBox(height: 8),
              LabeledField(
                label: '接口地址',
                controller: _base,
                hint: _defaultBase(_kind),
                mono: true,
                helper: '可直接填写兼容服务的 Base URL。SearXNG 需填写实例地址。',
              ),
              LabeledField(
                label: 'API Key',
                controller: _key,
                hint: edit ? widget.existing!.maskedKey : '留空表示未配置',
                obscure: true,
                mono: true,
                helper: edit
                    ? '留空表示不修改。Key 只保存在本机。'
                    : 'Key 只保存在本机 settings.json。',
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  void _save() {
    final String name = _name.text.trim();
    final String base = _base.text.trim();
    if (name.isEmpty || base.isEmpty) return;
    final SearchProviderConfig? old = widget.existing;
    final String key = _key.text.trim();
    final SearchProviderConfig value = old == null
        ? SearchProviderConfig.create(
            name: name,
            kind: _kind,
            baseUrl: base,
            apiKey: key,
          )
        : old.copyWith(
            name: name,
            kind: _kind,
            baseUrl: base,
            apiKey: key.isEmpty ? old.apiKey : key,
          );
    Navigator.of(context).pop(value);
  }
}

String _defaultBase(String kind) => switch (kind) {
  'tavily' => 'https://api.tavily.com',
  'exa' => 'https://api.exa.ai',
  'serper' => 'https://google.serper.dev',
  'searxng' => 'https://your-searxng.example',
  _ => 'https://your-search.example',
};
