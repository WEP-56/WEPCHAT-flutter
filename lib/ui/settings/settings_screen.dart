import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/responsive.dart';
import '../../theme/palette.dart';
import 'sections/appearance_section.dart';
import 'sections/memory_section.dart';
import 'sections/model_section.dart';
import 'sections/provider_section.dart';
import 'sections/search_section.dart';
import 'sections/tools_section.dart';
import 'sections/workspace_section.dart';

class _SectionSpec {
  const _SectionSpec(this.id, this.label, this.icon);

  final String id;
  final String label;
  final IconData icon;
}

const List<_SectionSpec> _kSections = <_SectionSpec>[
  _SectionSpec('provider', '模型服务', Icons.hub_outlined),
  _SectionSpec('model', '生成参数', Icons.tune),
  _SectionSpec('search', '搜索后端', Icons.travel_explore),
  _SectionSpec('tools', '工具权限', Icons.security_outlined),
  _SectionSpec('memory', '记忆', Icons.psychology_alt_outlined),
  _SectionSpec('appearance', '外观', Icons.palette_outlined),
  _SectionSpec('workspace', '工作区', Icons.folder_outlined),
];

/// 设置页。宽屏左侧是分区导航，窄屏是一条竖向长列表。
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialSectionId});

  /// 打开后直接定位到某个分区，取值见 [_kSections] 的 id。
  final String? initialSectionId;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final ScrollController _scroll = ScrollController();
  final Map<String, GlobalKey> _anchors = <String, GlobalKey>{
    for (final _SectionSpec spec in _kSections) spec.id: GlobalKey(),
  };

  late String _activeId = widget.initialSectionId ?? _kSections.first.id;

  @override
  void initState() {
    super.initState();
    final String? initial = widget.initialSectionId;
    if (initial == null) return;
    if (!_anchors.containsKey(initial)) {
      throw ArgumentError.value(initial, 'initialSectionId', '未知设置分区');
    }
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _jumpTo(initial, animate: false);
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _jumpTo(String id, {bool animate = true}) {
    final BuildContext? anchor = _anchors[id]?.currentContext;
    if (anchor == null) return;
    unawaited(
      Scrollable.ensureVisible(
        anchor,
        duration: animate ? const Duration(milliseconds: 240) : Duration.zero,
        curve: Curves.easeOut,
        alignment: 0.02,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool compact = isCompact(context);

    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: palette.bg,
        surfaceTintColor: Colors.transparent,
        shape: Border(bottom: BorderSide(color: palette.border)),
        title: Text(
          '设置',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: palette.text1,
          ),
        ),
      ),
      body: SafeArea(
        child: Row(
          children: <Widget>[
            if (!compact) ...<Widget>[
              _buildNav(palette),
              Container(width: 1, color: palette.border),
            ],
            Expanded(child: _buildContent(compact)),
          ],
        ),
      ),
    );
  }

  Widget _buildNav(AppPalette palette) {
    return Container(
      width: 176,
      color: palette.bgSide,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        children: _kSections.map((_SectionSpec spec) {
          final bool selected = spec.id == _activeId;
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: InkWell(
              onTap: () {
                setState(() => _activeId = spec.id);
                _jumpTo(spec.id);
              },
              borderRadius: BorderRadius.circular(8),
              hoverColor: palette.hover,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                decoration: BoxDecoration(
                  color: selected ? palette.active : Colors.transparent,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: <Widget>[
                    Icon(
                      spec.icon,
                      size: 15,
                      color: selected ? palette.accent : palette.text2,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      spec.label,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: palette.text1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildContent(bool compact) {
    return ListView(
      controller: _scroll,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 20,
        vertical: 16,
      ),
      children: <Widget>[
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _kSections.map((_SectionSpec spec) {
                return Padding(
                  key: _anchors[spec.id],
                  padding: const EdgeInsets.only(bottom: 14),
                  child: _sectionFor(spec.id),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }

  Widget _sectionFor(String id) {
    return switch (id) {
      'provider' => const ProviderSection(),
      'model' => const ModelSection(),
      'search' => const SearchSection(),
      'tools' => const ToolsSection(),
      'memory' => const MemorySection(),
      'appearance' => const AppearanceSection(),
      'workspace' => const WorkspaceSection(),
      _ => throw ArgumentError.value(id, 'id', '未知设置分区'),
    };
  }
}
