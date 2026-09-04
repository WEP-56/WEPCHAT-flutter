/// 编辑单个模型的元数据（实施 TODO §4.2、§10-4）。
///
/// 为什么要让用户改这些：`/models` 只给一个 id，视觉、思考、缓存、
/// `max_tokens` 字段名一个都不告诉我们，而这些差异恰恰决定请求发不发得出去。
/// 内置一份"模型 id → 能力"的表在中转站面前必然过期，所以做成可编辑的。
library;

import 'package:flutter/material.dart';

import '../../ai/model_catalog.dart';
import '../../ai/model_compat.dart';
import '../../state/app_scope.dart';
import '../../theme/palette.dart';
import '../widgets/menu_picker.dart';
import '../widgets/segmented_control.dart';
import 'dialog_bits.dart';

/// 打开模型参数弹窗。
Future<void> showModelMetaDialog(BuildContext context, ModelSpec model) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _ModelMetaDialog(model: model),
  );
}

String _cacheLabel(CacheControlFormat f) => switch (f) {
  CacheControlFormat.none => '不需要（或服务端自动）',
  CacheControlFormat.anthropic => 'Anthropic cache_control',
};

class _ModelMetaDialog extends StatefulWidget {
  const _ModelMetaDialog({required this.model});

  final ModelSpec model;

  @override
  State<_ModelMetaDialog> createState() => _ModelMetaDialogState();
}

class _ModelMetaDialogState extends State<_ModelMetaDialog> {
  late final TextEditingController _name = TextEditingController(
    // 用 displayName 会把 id 填进去（没设名字时它就返回 id），那样一保存就
    // 多出一个和 id 相同的 displayName。所以留空表示「跟 id 一样」。
    text: widget.model.displayName == widget.model.id
        ? ''
        : widget.model.displayName,
  );
  late final TextEditingController _window = TextEditingController(
    text: widget.model.contextWindow.toString(),
  );
  late final TextEditingController _maxOut = TextEditingController(
    text: widget.model.maxOutputTokens.toString(),
  );

  late ModelCompat _compat = widget.model.compat;

  /// 高级项默认折叠：正常端点一个都不用改，摊开只会让人以为必须逐个确认。
  bool _advanced = false;

  @override
  void dispose() {
    _name.dispose();
    _window.dispose();
    _maxOut.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return AlertDialog(
      title: Text(widget.model.id, style: const TextStyle(fontSize: 15)),
      content: SizedBox(
        width: dialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              LabeledField(
                label: '显示名',
                controller: _name,
                hint: widget.model.id,
                helper: '留空就用模型 id。',
              ),
              Row(
                children: <Widget>[
                  Expanded(
                    child: LabeledField(
                      label: '上下文窗口',
                      controller: _window,
                      numeric: true,
                      mono: true,
                      helper: '超出后触发压缩。',
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: LabeledField(
                      label: '最大输出',
                      controller: _maxOut,
                      numeric: true,
                      mono: true,
                      helper: '单次回复上限。',
                    ),
                  ),
                ],
              ),
              SwitchRow(
                label: '视觉输入',
                desc: '能不能发图片给它。',
                value: _compat.visionInput,
                onChanged: (bool v) =>
                    setState(() => _compat = _compat.copyWith(visionInput: v)),
              ),
              SwitchRow(
                label: '支持 temperature',
                desc: 'OpenAI o 系列要关掉，它拒绝这个字段。',
                value: _compat.supportsTemperature,
                onChanged: (bool v) => setState(
                  () => _compat = _compat.copyWith(supportsTemperature: v),
                ),
              ),
              SwitchRow(
                label: '支持思考',
                desc: '在输入框用统一的 low → max 等级调节。',
                value: _compat.thinking != ThinkingFormat.none,
                onChanged: (bool enabled) => setState(() {
                  if (!enabled) {
                    _compat = _compat.copyWith(thinking: ThinkingFormat.none);
                    return;
                  }
                  final ThinkingFormat format =
                      _compat.thinking != ThinkingFormat.none
                          ? _compat.thinking
                          : (widget.model.providerId.toLowerCase().contains(
                                  'anthropic',
                                )
                                ? ThinkingFormat.anthropicThinking
                                : ThinkingFormat.openaiReasoningEffort);
                  _compat = _compat.copyWith(thinking: format);
                }),
              ),
              _pickerRow(
                palette,
                'Prompt 缓存',
                MenuPicker<CacheControlFormat>(
                  tooltip: '选择缓存方式',
                  value: _compat.cache,
                  options: <SegOption<CacheControlFormat>>[
                    for (final CacheControlFormat f
                        in CacheControlFormat.values)
                      SegOption<CacheControlFormat>(f, _cacheLabel(f)),
                  ],
                  onChanged: (CacheControlFormat f) =>
                      setState(() => _compat = _compat.copyWith(cache: f)),
                ),
              ),
              const SizedBox(height: 2),
              InkWell(
                onTap: () => setState(() => _advanced = !_advanced),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        _advanced ? Icons.expand_less : Icons.expand_more,
                        size: 16,
                        color: palette.text3,
                      ),
                      const SizedBox(width: 4),
                      const DialogGroupLabel('高级（请求字段兼容性）'),
                    ],
                  ),
                ),
              ),
              if (_advanced) ..._advancedRows(palette),
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

  Widget _pickerRow(AppPalette palette, String label, Widget picker) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: palette.text1),
            ),
          ),
          picker,
        ],
      ),
    );
  }

  List<Widget> _advancedRows(AppPalette palette) {
    return <Widget>[
      _pickerRow(
        palette,
        '输出上限字段名',
        SegmentedControl<String>(
          small: true,
          value: _compat.maxTokensField,
          options: const <SegOption<String>>[
            SegOption<String>('max_tokens', 'max_tokens'),
            SegOption<String>('max_completion_tokens', 'max_completion'),
          ],
          onChanged: (String v) =>
              setState(() => _compat = _compat.copyWith(maxTokensField: v)),
        ),
      ),
      SwitchRow(
        label: 'system 用 developer 角色',
        desc: 'OpenAI o 系列推荐；旧模型只认 system。',
        value: _compat.supportsDeveloperRole,
        onChanged: (bool v) => setState(
          () => _compat = _compat.copyWith(supportsDeveloperRole: v),
        ),
      ),
      SwitchRow(
        label: '支持 prompt_cache_key',
        desc: 'OpenAI 官方端点支持；兼容端点大多不认。',
        value: _compat.supportsPromptCacheKey,
        onChanged: (bool v) => setState(
          () => _compat = _compat.copyWith(supportsPromptCacheKey: v),
        ),
      ),
      SwitchRow(
        label: '支持并行工具调用',
        desc: '部分兼容端点一轮只能回一个工具调用。',
        value: _compat.supportsParallelToolCalls,
        onChanged: (bool v) => setState(
          () => _compat = _compat.copyWith(supportsParallelToolCalls: v),
        ),
      ),
      SwitchRow(
        label: '工具结果必须带 name',
        desc: '部分自建 vLLM / Ollama 需要。',
        value: _compat.requiresToolResultName,
        onChanged: (bool v) => setState(
          () => _compat = _compat.copyWith(requiresToolResultName: v),
        ),
      ),
    ];
  }

  void _save() {
    // 填了非法数字就保持原值，不弹错：这两个框是"改不改都能用"的东西，
    // 为一个笔误挡住其他改动不值得。
    final int window =
        int.tryParse(_window.text.trim()) ?? widget.model.contextWindow;
    final int maxOut =
        int.tryParse(_maxOut.text.trim()) ?? widget.model.maxOutputTokens;

    context.settings.updateModel(
      widget.model.key,
      displayName: _name.text.trim(),
      contextWindow: window <= 0 ? widget.model.contextWindow : window,
      maxOutputTokens: maxOut <= 0 ? widget.model.maxOutputTokens : maxOut,
      compat: _compat,
    );
    Navigator.of(context).pop();
  }
}
