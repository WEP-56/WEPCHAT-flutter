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
      // 顶栏和左侧导航共用外壳色，内容面在下方用色差和圆角浮起 —— 和
      // ExpandedShell 是同一套结构，从会话页进设置时外壳看起来是连续的。
      backgroundColor: palette.bgSide,
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: palette.bgSide,
        surfaceTintColor: Colors.transparent,
        // 内容滚动到顶栏下面时不加高程：M3 默认会叠一层色调，看着像多了条边界。
        scrolledUnderElevation: 0,
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
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!compact) _buildNav(palette),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(top: 10),
                child: ClipRRect(
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(16),
                    topRight: Radius.circular(16),
                  ),
                  child: ColoredBox(
                    color: palette.bg,
                    child: _buildContent(compact),
                  ),
                ),
              ),
            ),
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

  /// 内容区滚动。
  ///
  /// 用 [SingleChildScrollView] 而不是只有一个 child 的 ListView：ListView 会给
  /// 每个 item 套一层 `IndexedSemantics`，把整页合并成一个语义节点，页内多个
  /// Tooltip 的 OverlayPortal 锚点也被并进去 —— 上游 flutter#182444 在这种情况下
  /// 只保留第一个锚点的遍历标识，剩下的悬浮层节点没了父节点，Windows 的
  /// accessibility bridge 于是在滚动时不停报 `Failed to update ui::AXTree`。
  /// 这里的分区是一次性全建出来的，本来也不需要懒加载。
  Widget _buildContent(bool compact) {
    return SingleChildScrollView(
      controller: _scroll,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 20,
        vertical: 16,
      ),
      // 竖向滚动里高度是无界的，Center 会按内容高度收缩，只负责水平居中。
      child: Center(
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
