/// 添加 / 编辑提供商的弹窗（实施 TODO §10-4）。
///
/// 用户只填四项：**名称、API 类别、baseUrl、Key**。没有「预设厂商」列表——
/// 首启种子里已经带了常见的几家（`kSeedProviders`），这个弹窗是给种子里
/// 没有的端点用的：中转站、本地 vLLM、公司内网网关。给这些东西做预设没意义。
library;

import 'package:flutter/material.dart';

import '../../ai/provider_config.dart';
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

  String? _nameError;
  String? _urlError;

  @override
  void dispose() {
    _name.dispose();
    _baseUrl.dispose();
    _apiKey.dispose();
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
    final ProviderConfig? existing = widget.existing;

    final ProviderConfig saved;
    if (existing == null) {
      saved = settings.addProvider(
        displayName: name,
        apiKind: _kind,
        baseUrl: url,
        apiKey: key,
      );
    } else {
      settings.updateProvider(
        existing.id,
        displayName: name,
        apiKind: _kind,
        baseUrl: url,
        // 留空 = 不改。传 '' 会把已配好的 key 清掉。
        apiKey: key.isEmpty ? null : key,
      );
      saved = settings.providerOf(existing.id)!;
    }
    Navigator.of(context).pop(saved);
  }
}
