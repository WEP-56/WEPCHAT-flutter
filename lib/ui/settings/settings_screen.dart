import 'package:flutter/material.dart';

import '../../app/responsive.dart';
import '../../theme/palette.dart';
import 'sections/appearance_section.dart';
import 'sections/browser_section.dart';
import 'sections/memory_section.dart';
import 'sections/model_section.dart';
import 'sections/provider_section.dart';
import 'sections/search_section.dart';
import 'sections/tools_section.dart';
import 'sections/workspace_section.dart';

class _SectionSpec {
  const _SectionSpec(this.id, this.label, this.description, this.icon);
  final String id;
  final String label;
  final String description;
  final IconData icon;
}

/// Android 先显示一级分类；桌面保留左侧分类导航，右侧只刷新当前二级页。
const List<_SectionSpec> _kSections = <_SectionSpec>[
  _SectionSpec('model_service', '模型服务', '提供商、模型与生成参数', Icons.hub_outlined),
  _SectionSpec('search', '网络搜索', '网页搜索服务与联网能力', Icons.travel_explore),
  _SectionSpec('tools', '工具权限', '文件、脚本和网络工具的授权', Icons.security_outlined),
  _SectionSpec('memory', '记忆配置', '管理可跨会话使用的记忆', Icons.psychology_alt_outlined),
  _SectionSpec('appearance', '外观', '主题、强调色与显示偏好', Icons.palette_outlined),
  _SectionSpec('storage', '存储', '工作区和本地数据位置', Icons.folder_outlined),
  _SectionSpec('browser', '浏览器', '内置浏览器与历史记录', Icons.language_outlined),
];

String? _canonicalSectionId(String? id) {
  if (id == null) return null;
  return switch (id) {
    'provider' || 'model' => 'model_service',
    'workspace' => 'storage',
    _ => id,
  };
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, this.initialSectionId});
  final String? initialSectionId;

  @override
  Widget build(BuildContext context) {
    final String? sectionId = _canonicalSectionId(initialSectionId);
    if (sectionId != null &&
        _kSections.every((_SectionSpec spec) => spec.id != sectionId)) {
      throw ArgumentError.value(initialSectionId, 'initialSectionId', '未知设置分区');
    }
    return _SettingsScaffold(selectedId: sectionId);
  }
}

class _SettingsScaffold extends StatefulWidget {
  const _SettingsScaffold({required this.selectedId});
  final String? selectedId;

  @override
  State<_SettingsScaffold> createState() => _SettingsScaffoldState();
}

class _SettingsScaffoldState extends State<_SettingsScaffold> {
  late String? _selectedId = widget.selectedId;

  void _select(String id) => setState(() => _selectedId = id);

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool compact = isCompact(context);
    final _SectionSpec? selected = _selectedId == null
        ? null
        : _kSections.firstWhere((_SectionSpec spec) => spec.id == _selectedId);

    return Scaffold(
      backgroundColor: palette.bgSide,
      appBar: AppBar(
        toolbarHeight: 50,
        backgroundColor: palette.bgSide,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: compact && selected != null
            ? BackButton(onPressed: () => Navigator.pop(context))
            : null,
        title: Text(
          selected?.label ?? '设置',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: palette.text1,
          ),
        ),
      ),
      body: SafeArea(
        child: compact
            ? (selected == null
                  ? _CategoryList(
                      onSelected: (String id) {
                        Navigator.of(context).push<void>(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SettingsScreen(initialSectionId: id),
                          ),
                        );
                      },
                    )
                  : _DetailContent(sectionId: selected.id))
            : Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  _DesktopNav(
                    selectedId: selected?.id ?? _kSections.first.id,
                    onSelected: _select,
                  ),
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
                          child: _DetailContent(
                            sectionId: selected?.id ?? _kSections.first.id,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
      ),
    );
  }
}

class _CategoryList extends StatelessWidget {
  const _CategoryList({required this.onSelected});
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(12, 16, 12, 24),
      addSemanticIndexes: false,
      itemCount: _kSections.length,
      separatorBuilder: (BuildContext context, int index) =>
          const SizedBox(height: 8),
      itemBuilder: (BuildContext context, int index) {
        final _SectionSpec spec = _kSections[index];
        return InkWell(
          onTap: () => onSelected(spec.id),
          borderRadius: BorderRadius.circular(12),
          child: Ink(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: palette.bgPanel,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: <Widget>[
                Icon(spec.icon, color: palette.accent, size: 21),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        spec.label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: palette.text1,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        spec.description,
                        style: TextStyle(fontSize: 11.5, color: palette.text3),
                      ),
                    ],
                  ),
                ),
                Icon(Icons.chevron_right, color: palette.text3, size: 20),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _DesktopNav extends StatelessWidget {
  const _DesktopNav({required this.selectedId, required this.onSelected});
  final String selectedId;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return SizedBox(
      width: 176,
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        addSemanticIndexes: false,
        children: _kSections.map((_SectionSpec spec) {
          final bool selected = spec.id == selectedId;
          return Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: InkWell(
              onTap: () => onSelected(spec.id),
              borderRadius: BorderRadius.circular(8),
              hoverColor: palette.hover,
              child: Ink(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
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
                      style: TextStyle(fontSize: 12.5, color: palette.text1),
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
}

class _DetailContent extends StatelessWidget {
  const _DetailContent({required this.sectionId});
  final String sectionId;

  @override
  Widget build(BuildContext context) {
    final bool compact = isCompact(context);
    return SingleChildScrollView(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 12 : 20,
        vertical: 16,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _sectionFor(sectionId),
        ),
      ),
    );
  }
}

Widget _sectionFor(String id) {
  return switch (id) {
    'model_service' => const Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ProviderSection(),
        SizedBox(height: 14),
        ModelSection(),
      ],
    ),
    'search' => const SearchSection(),
    'tools' => const ToolsSection(),
    'memory' => const MemorySection(),
    'appearance' => const AppearanceSection(),
    'storage' => const WorkspaceSection(),
    'browser' => const BrowserSection(),
    _ => throw ArgumentError.value(id, 'id', '未知设置分区'),
  };
}
