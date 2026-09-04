/// 添加 / 编辑提供商的弹窗（实施 TODO §10-4）。
///
/// 用户基础配置只填四项：**名称、API 类别、baseUrl、Key**；高级设置可补充请求头。
/// 没有「预设厂商」列表——
/// 首启种子里已经带了常见的几家（`kSeedProviders`），这个弹窗是给种子里
/// 没有的端点用的：中转站、本地 vLLM、公司内网网关。给这些东西做预设没意义。
library;

import 'package:flutter/material.dart';

import '../../ai/provider_config.dart';
import '../../ai/provider_headers.dart';
import '../../state/app_scope.dart';
import '../../state/app_settings.dart';
import '../../theme/palette.dart';
import 'dialog_bits.dart';

/// 打开提供商表单。[existing] 为空表示新建。
///
/// 返回新建或被编辑的 provider；用户取消时返回 null。新建后调用方可以直接
/// 接着打开模型弹窗——刚填完 key 的下一步一定是挑模型。
Future<ProviderConfig?> showProviderDialog(
  BuildContext context, {
  ProviderConfig? existing,
}) {
  return showDialog<ProviderConfig>(
    context: context,
    builder: (BuildContext ctx) => _ProviderDialog(existing: existing),
  );
}

class _ProviderDialog extends StatefulWidget {
  const _ProviderDialog({this.existing});

  final ProviderConfig? existing;

  @override
  State<_ProviderDialog> createState() => _ProviderDialogState();
}

class _ProviderDialogState extends State<_ProviderDialog> {
  late final TextEditingController _name = TextEditingController(
    text: widget.existing?.displayName ?? '',
  );
  late final TextEditingController _baseUrl = TextEditingController(
    text: widget.existing?.baseUrl ?? '',
  );

  /// Key 输入框在编辑时**留空**，提示位显示掩码。
  ///
  /// 不把已存的 key 填回输入框：一是界面不显示明文（§13.4），二是留空即
  /// 「不修改」，用户改个名字不会因为输入框里那串东西被意外覆盖。
  final TextEditingController _apiKey = TextEditingController();

  late ApiKind _kind = widget.existing?.apiKind ?? ApiKind.openaiCompletions;
  late String _preset = _presetFor(widget.existing?.customHeaders);
  late final TextEditingController _presetVersion = TextEditingController(
    text: providerHeaderPresetDefaultVersion(_preset),
  );
  late final List<_HeaderDraft> _headers = <_HeaderDraft>[
    for (final MapEntry<String, String> entry
        in (widget.existing?.customHeaders ?? const <String, String>{}).entries)
      _HeaderDraft(entry.key, entry.value),
  ];

  String? _nameError;
  String? _urlError;
  String? _headersError;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
    _presetVersion.dispose();
    for (final _HeaderDraft header in _headers) {
      header.dispose();
    }
    super.dispose();
  }

  bool get _isEdit => widget.existing != null;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return AlertDialog(
      title: Text(
        _isEdit ? '编辑提供商' : '添加提供商',
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
                hint: '例如 DeepSeek、公司网关',
                error: _nameError,
                autofocus: !_isEdit,
                helper: '只影响界面显示，随便起。',
              ),
              _kindPicker(palette),
              LabeledField(
                label: 'baseUrl',
                controller: _baseUrl,
                hint: 'https://api.deepseek.com/v1',
                error: _urlError,
                mono: true,
                helper: '填到 /v1 为止，不要带 /chat/completions。',
              ),
              LabeledField(
                label: 'API Key',
                controller: _apiKey,
                hint: _isEdit ? widget.existing!.maskedKey : 'sk-...',
                obscure: true,
                mono: true,
                helper: _isEdit
                    ? '留空表示不修改。Key 存在本机，界面不显示明文。'
                    : 'Key 存在本机的 settings.json，界面不显示明文。',
                onSubmitted: (String _) => _save(),
              ),
              _advanced(palette),
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

  Widget _advanced(AppPalette palette) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(bottom: 4),
        title: Text(
          '高级配置',
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: palette.text1,
          ),
        ),
        subtitle: Text(
          _headers.isEmpty ? '客户端标识与自定义请求头' : '已配置 ${_headers.length} 个请求头',
          style: TextStyle(fontSize: 10.5, color: palette.text3),
        ),
        children: <Widget>[
          _presetPicker(palette),
          if (_preset != 'none' && _preset != 'custom')
            LabeledField(
              label: '客户端版本',
              controller: _presetVersion,
              hint: '例如 2.1.260',
              mono: true,
              helper: '预设只填充请求头，版本可以按供应商要求修改。',
              onChanged: (String version) {
                if (_preset != 'none' && _preset != 'custom') {
                  setState(
                    () =>
                        _replaceHeaders(providerHeaderPreset(_preset, version)),
                  );
                }
              },
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '自定义请求头',
              style: TextStyle(fontSize: 11.5, color: palette.text2),
            ),
          ),
          const SizedBox(height: 5),
          for (int i = 0; i < _headers.length; i++)
            _headerRow(palette, i, _headers[i]),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () =>
                  setState(() => _headers.add(_HeaderDraft('', ''))),
              icon: const Icon(Icons.add, size: 15),
              label: const Text('添加请求头'),
            ),
          ),
          if (_headersError != null)
            Text(
              _headersError!,
              style: TextStyle(fontSize: 10.5, color: palette.danger),
            ),
          Text(
            '预设仅调整请求头，不会改变 API 路径、请求体或工具调用协议。',
            style: TextStyle(fontSize: 10.5, color: palette.text3),
          ),
        ],
      ),
    );
  }

  Widget _presetPicker(AppPalette palette) {
    const List<(String, String)> options = <(String, String)>[
      ('none', '默认'),
      ('opencode', 'OpenCode'),
      ('codex', 'Codex'),
      ('claudeCode', 'Claude Code'),
      ('custom', '自定义'),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: DropdownButtonFormField<String>(
        initialValue: _preset,
        isExpanded: true,
        decoration: const InputDecoration(labelText: '客户端标识预设'),
        items: <DropdownMenuItem<String>>[
          for (final (String id, String label) in options)
            DropdownMenuItem<String>(value: id, child: Text(label)),
        ],
        onChanged: (String? value) {
          if (value == null) return;
          setState(() {
            _preset = value;
            if (value != 'custom') {
              _presetVersion.text = providerHeaderPresetDefaultVersion(value);
              _replaceHeaders(providerHeaderPreset(value, _presetVersion.text));
            }
          });
        },
      ),
    );
  }

  Widget _headerRow(AppPalette palette, int index, _HeaderDraft draft) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Expanded(
            flex: 4,
            child: TextField(
              controller: draft.name,
              style: const TextStyle(fontSize: 11.5),
              decoration: const InputDecoration(hintText: 'Header 名称'),
              onChanged: (_) => setState(() => _preset = 'custom'),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            flex: 5,
            child: TextField(
              controller: draft.value,
              style: const TextStyle(fontSize: 11.5),
              decoration: const InputDecoration(hintText: 'Header 值'),
              onChanged: (_) => setState(() => _preset = 'custom'),
            ),
          ),
          IconButton(
            tooltip: '删除',
            onPressed: () => setState(() {
              draft.dispose();
              _headers.removeAt(index);
              _preset = 'custom';
            }),
            icon: Icon(Icons.close, size: 16, color: palette.text3),
            constraints: const BoxConstraints.tightFor(width: 28, height: 36),
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  void _replaceHeaders(Map<String, String> values) {
    for (final _HeaderDraft header in _headers) {
      header.dispose();
    }
    _headers
      ..clear()
      ..addAll(
        values.entries.map(
          (MapEntry<String, String> e) => _HeaderDraft(e.key, e.value),
        ),
      );
  }

  Widget _kindPicker(AppPalette palette) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'API 类别',
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: palette.text2,
            ),
          ),
          const SizedBox(height: 5),
          // 三个选项用 RadioListTile 而不是下拉：选错这一项的后果是所有请求
          // 都失败，而每项的 hint 才是用户真正需要读的东西，藏在下拉里没用。
          for (final ApiKind kind in ApiKind.values)
            InkWell(
              onTap: () => setState(() => _kind = kind),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 5),
                child: Row(
                  children: <Widget>[
                    Icon(
                      kind == _kind
                          ? Icons.radio_button_checked
                          : Icons.radio_button_unchecked,
                      size: 16,
                      color: kind == _kind ? palette.accent : palette.text3,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            kind.label,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w500,
                              color: palette.text1,
                            ),
                          ),
                          Text(
                            kind.hint,
                            style: TextStyle(
                              fontSize: 10.5,
                              color: palette.text3,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _save() {
    final String name = _name.text.trim();
    final String url = _baseUrl.text.trim();

    setState(() {
      _nameError = name.isEmpty ? '起个名字' : null;
      // 只挡明显不对的：不校验路径形状，中转站的地址千奇百怪，
      // 挡住一个能用的地址比放过一个不能用的更烦人。
      _urlError = url.isEmpty
          ? '填上端点地址'
          : (url.startsWith('http://') || url.startsWith('https://'))
          ? null
          : '要以 http:// 或 https:// 开头';
    });
    if (_nameError != null || _urlError != null) return;

    final AppSettings settings = context.settings;
    final String key = _apiKey.text.trim();
    final Map<String, String>? customHeaders = _readHeaders();
    if (customHeaders == null) return;
    final ProviderConfig? existing = widget.existing;

    final ProviderConfig saved;
    if (existing == null) {
      saved = settings.addProvider(
        displayName: name,
        apiKind: _kind,
        baseUrl: url,
        apiKey: key,
        customHeaders: customHeaders,
      );
    } else {
      settings.updateProvider(
        existing.id,
        displayName: name,
        apiKind: _kind,
        baseUrl: url,
        // 留空 = 不改。传 '' 会把已配好的 key 清掉。
        apiKey: key.isEmpty ? null : key,
        customHeaders: customHeaders,
      );
      saved = settings.providerOf(existing.id)!;
    }
    Navigator.of(context).pop(saved);
  }

  Map<String, String>? _readHeaders() {
    final Map<String, String> result = <String, String>{};
    for (final _HeaderDraft draft in _headers) {
      final String name = draft.name.text.trim();
      final String value = draft.value.text.trim();
      if (name.isEmpty && value.isEmpty) continue;
      if (name.isEmpty || value.isEmpty) {
        setState(() => _headersError = '请求头名称和值都必须填写');
        return null;
      }
      if (!isValidProviderHeaderName(name) ||
          !isValidProviderHeaderValue(value) ||
          kForbiddenProviderHeaderNames.contains(name.toLowerCase())) {
        setState(() => _headersError = '请求头名称无效或属于受保护的传输层 Header');
        return null;
      }
      final String lower = name.toLowerCase();
      if (result.keys.any((String key) => key.toLowerCase() == lower)) {
        setState(() => _headersError = '请求头名称不能重复（不区分大小写）');
        return null;
      }
      result[name] = value;
    }
    _headersError = null;
    return result;
  }

  static String _presetFor(Map<String, String>? headers) {
    if (headers == null || headers.isEmpty) return 'none';
    for (final String preset in <String>['opencode', 'codex', 'claudeCode']) {
      final Map<String, String> expected = providerHeaderPreset(
        preset,
        providerHeaderPresetDefaultVersion(preset),
      );
      if (_sameHeaderNamesAndValues(headers, expected)) return preset;
    }
    return 'custom';
  }

  static bool _sameHeaderNamesAndValues(
    Map<String, String> left,
    Map<String, String> right,
  ) {
    if (left.length != right.length) return false;
    for (final MapEntry<String, String> entry in right.entries) {
      String? value;
      for (final MapEntry<String, String> candidate in left.entries) {
        if (candidate.key.toLowerCase() == entry.key.toLowerCase()) {
          value = candidate.value;
          break;
        }
      }
      if (value != entry.value) return false;
    }
    return true;
  }
}

class _HeaderDraft {
  _HeaderDraft(String name, String value)
    : name = TextEditingController(text: name),
      value = TextEditingController(text: value);

  final TextEditingController name;
  final TextEditingController value;

  void dispose() {
    name.dispose();
    value.dispose();
  }
}
