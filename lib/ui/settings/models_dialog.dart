/// 管理一个提供商下的模型（实施 TODO §10-4）。
///
/// 三件事：从 `/models` 拉、手动加、逐个测可用性。拉取之后**不直接全加**，
/// 而是让用户勾选——中转站的 `/models` 常返回几百个 id，全加进去会把聊天
/// 顶栏的选择器变成一本电话簿。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../../ai/model_catalog.dart';
import '../../ai/model_compat.dart';
import '../../ai/model_discovery.dart';
import '../../ai/provider_config.dart';
import '../../core/errors.dart';
import '../../state/app_scope.dart';
import '../../state/app_settings.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/toast.dart';
import 'dialog_bits.dart';
import 'model_meta_dialog.dart';

/// 打开某个提供商的模型管理弹窗。
Future<void> showModelsDialog(BuildContext context, String providerId) {
  return showDialog<void>(
    context: context,
    builder: (BuildContext ctx) => _ModelsDialog(providerId: providerId),
  );
}

class _ModelsDialog extends StatefulWidget {
  const _ModelsDialog({required this.providerId});

  final String providerId;

  @override
  State<_ModelsDialog> createState() => _ModelsDialogState();
}

class _ModelsDialogState extends State<_ModelsDialog> {
  final TextEditingController _manual = TextEditingController();

  /// 探测结果按 model key 存。留在内存里不落盘：这是「刚才那一下通不通」，
  /// 不是模型的属性，重开弹窗重新测更准。
  final Map<String, ProbeResult> _probes = <String, ProbeResult>{};
  final Set<String> _probing = <String>{};

  bool _fetching = false;

  @override
  void dispose() {
    _manual.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        final ProviderConfig? config = settings.providerOf(widget.providerId);
        // provider 在弹窗开着的时候被删了（另一处操作）：直接收摊，
        // 继续显示一个不存在的 provider 的模型只会让人以为还在。
        if (config == null) return const SizedBox.shrink();

        final List<ModelSpec> models =
            settings.modelsOfProvider(widget.providerId);

        return AlertDialog(
          title: Text(
            '${config.displayName} · 模型',
            style: const TextStyle(fontSize: 15),
          ),
          content: SizedBox(
            width: dialogWidth(context),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _header(config),
                const SizedBox(height: 10),
                _addRow(config),
                const Divider(height: 18),
                if (models.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    child: Text(
                      '还没有模型。上面「获取模型」或手动填一个模型名。',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.palette.text3,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: models.length,
                      itemBuilder: (BuildContext _, int i) => _ModelRow(
                        model: models[i],
                        probe: _probes[models[i].key],
                        busy: _probing.contains(models[i].key),
                        onProbe: () => unawaited(_probe(models[i], config)),
                        onEdit: () =>
                            unawaited(showModelMetaDialog(context, models[i])),
                        onRemove: () => settings.removeModel(models[i].key),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }

  /// 顶部一行：协议种类 + key 状态。没配 key 时把话说在获取按钮之前。
  Widget _header(ProviderConfig config) {
    final AppPalette palette = context.palette;
    return Row(
      children: <Widget>[
        Pill(config.apiKind.label, tone: PillTone.accent),
        const SizedBox(width: 6),
        config.isConfigured
            ? const Pill('已配置 Key', tone: PillTone.good)
            : const Pill('未配置 Key', tone: PillTone.warn),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            config.baseUrl,
            overflow: TextOverflow.ellipsis,
            style: AppFonts.mono(size: 10.5, color: palette.text3),
          ),
        ),
      ],
    );
  }

  Widget _addRow(ProviderConfig config) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: TextField(
            controller: _manual,
            style: AppFonts.mono(size: 12.5, color: context.palette.text1),
            decoration: const InputDecoration(
              isDense: true,
              hintText: '手动填模型名，如 deepseek-chat',
              contentPadding: EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              border: OutlineInputBorder(),
            ),
            onSubmitted: (String _) => _addManual(config),
          ),
        ),
        const SizedBox(width: 6),
        OutlinedButton(
          onPressed: () => _addManual(config),
          child: const Text('添加'),
        ),
        const SizedBox(width: 6),
        FilledButton.icon(
          onPressed: _fetching ? null : () => unawaited(_fetch(config)),
          icon: _fetching
              ? const SizedBox(
                  width: 13,
                  height: 13,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.cloud_download_outlined, size: 15),
          label: const Text('获取模型'),
        ),
      ],
    );
  }

  void _addManual(ProviderConfig config) {
    final String id = _manual.text.trim();
    if (id.isEmpty) return;
    final ModelSpec? added = context.settings.addModel(
      providerId: config.id,
      modelId: id,
    );
    _manual.clear();
    if (added == null) showAppToast(context, '$id 已经在列表里了');
  }

  Future<void> _fetch(ProviderConfig config) async {
    setState(() => _fetching = true);
    try {
      final List<String> ids = await fetchModelIds(config);
      if (!mounted) return;
      if (ids.isEmpty) {
        showAppToast(context, '这个端点返回了空列表，手动添加吧');
        return;
      }

      final AppSettings settings = context.settings;
      final Set<String> already = settings
          .modelsOfProvider(config.id)
          .map((ModelSpec m) => m.id)
          .toSet();

      final List<String>? picked = await showDialog<List<String>>(
        context: context,
        builder: (BuildContext ctx) => _PickModelsDialog(
          ids: ids,
          already: already,
        ),
      );
      if (picked == null || picked.isEmpty || !mounted) return;

      final int count = settings.addModels(
        providerId: config.id,
        modelIds: picked,
      );
      showAppToast(context, '新增 $count 个模型');
    } on Object catch (e) {
      if (!mounted) return;
      showAppToast(context, _messageOf(e));
    } finally {
      if (mounted) setState(() => _fetching = false);
    }
  }

  Future<void> _probe(ModelSpec model, ProviderConfig config) async {
    setState(() => _probing.add(model.key));
    final ProbeResult result = await probeModel(model: model, config: config);
    if (!mounted) return;
    setState(() {
      _probing.remove(model.key);
      _probes[model.key] = result;
    });
  }
}

/// 错误文案：[WepError] 有给用户看的 message，其余退回 toString。
String _messageOf(Object error) =>
    error is WepError ? error.message : error.toString();

/// 模型列表里的一行。
class _ModelRow extends StatelessWidget {
  const _ModelRow({
    required this.model,
    required this.probe,
    required this.busy,
    required this.onProbe,
    required this.onEdit,
    required this.onRemove,
  });

  final ModelSpec model;
  final ProbeResult? probe;
  final bool busy;
  final VoidCallback onProbe;
  final VoidCallback onEdit;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final ProbeResult? result = probe;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  model.displayName,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.mono(size: 11.5, color: palette.text1),
                ),
              ),
              if (model.compat.visionInput) ...<Widget>[
                const SizedBox(width: 4),
                const Pill('视觉'),
              ],
              if (model.compat.thinking != ThinkingFormat.none) ...<Widget>[
                const SizedBox(width: 4),
                const Pill('思考'),
              ],
              const SizedBox(width: 4),
              busy
                  ? const SizedBox(
                      width: 28,
                      height: 28,
                      child: Center(
                        child: SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                    )
                  : IconAction(
                      icon: Icons.wifi_tethering,
                      tooltip: '测可用性（发一句 hi）',
                      size: 15,
                      box: 28,
                      onTap: onProbe,
                    ),
              IconAction(
                icon: Icons.tune,
                tooltip: '模型参数',
                size: 15,
                box: 28,
                onTap: onEdit,
              ),
              IconAction(
                icon: Icons.delete_outline,
                tooltip: '删除',
                size: 15,
                box: 28,
                tone: IconActionTone.danger,
                onTap: onRemove,
              ),
            ],
          ),
          if (result != null)
            Padding(
              padding: const EdgeInsets.only(left: 2, top: 2, bottom: 2),
              child: Row(
                children: <Widget>[
                  Icon(
                    result.ok ? Icons.check_circle : Icons.error_outline,
                    size: 12,
                    color: result.ok ? palette.good : palette.danger,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      result.elapsed == null
                          ? result.message
                          : '${result.message} · ${result.elapsed!.inMilliseconds}ms',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: result.ok ? palette.text3 : palette.danger,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// `/models` 拉回来之后的勾选弹窗。
///
/// 带搜索框：几百个 id 里找 `deepseek-chat` 靠滚动是不现实的。已经添加过的
/// 条目显示成禁用状态而不是隐藏——用户看到"它已经在了"才不会怀疑漏了。
class _PickModelsDialog extends StatefulWidget {
  const _PickModelsDialog({required this.ids, required this.already});

  final List<String> ids;
  final Set<String> already;

  @override
  State<_PickModelsDialog> createState() => _PickModelsDialogState();
}

class _PickModelsDialogState extends State<_PickModelsDialog> {
  final TextEditingController _filter = TextEditingController();
  final Set<String> _picked = <String>{};

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  List<String> get _visible {
    final String q = _filter.text.trim().toLowerCase();
    if (q.isEmpty) return widget.ids;
    return widget.ids
        .where((String id) => id.toLowerCase().contains(q))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final List<String> visible = _visible;
    final List<String> selectable = visible
        .where((String id) => !widget.already.contains(id))
        .toList();

    return AlertDialog(
      title: Text(
        '选择要添加的模型（${widget.ids.length} 个）',
        style: const TextStyle(fontSize: 15),
      ),
      content: SizedBox(
        width: dialogWidth(context),
        height: 380,
        child: Column(
          children: <Widget>[
            TextField(
              controller: _filter,
              autofocus: true,
              style: TextStyle(fontSize: 12.5, color: palette.text1),
              decoration: const InputDecoration(
                isDense: true,
                prefixIcon: Icon(Icons.search, size: 16),
                hintText: '筛选',
                contentPadding: EdgeInsets.symmetric(vertical: 10),
                border: OutlineInputBorder(),
              ),
              onChanged: (String _) => setState(() {}),
            ),
            Row(
              children: <Widget>[
                Text(
                  '已选 ${_picked.length}',
                  style: TextStyle(fontSize: 11, color: palette.text3),
                ),
                const Spacer(),
                TextButton(
                  onPressed: selectable.isEmpty
                      ? null
                      : () => setState(() => _picked.addAll(selectable)),
                  child: const Text('全选当前'),
                ),
                TextButton(
                  onPressed: _picked.isEmpty
                      ? null
                      : () => setState(_picked.clear),
                  child: const Text('清空'),
                ),
              ],
            ),
            Expanded(
              child: ListView.builder(
                itemCount: visible.length,
                itemBuilder: (BuildContext _, int i) {
                  final String id = visible[i];
                  final bool exists = widget.already.contains(id);
                  return CheckboxListTile(
                    dense: true,
                    value: exists || _picked.contains(id),
                    onChanged: exists
                        ? null
                        : (bool? on) => setState(() {
                              if (on ?? false) {
                                _picked.add(id);
                              } else {
                                _picked.remove(id);
                              }
                            }),
                    title: Text(
                      id,
                      style: AppFonts.mono(
                        size: 11.5,
                        color: exists ? palette.text3 : palette.text1,
                      ),
                    ),
                    subtitle: exists
                        ? Text(
                            '已添加',
                            style: TextStyle(
                              fontSize: 10,
                              color: palette.text3,
                            ),
                          )
                        : null,
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _picked.isEmpty
              ? null
              : () => Navigator.of(context).pop(_picked.toList()),
          child: Text('添加 ${_picked.length} 个'),
        ),
      ],
    );
  }
}
