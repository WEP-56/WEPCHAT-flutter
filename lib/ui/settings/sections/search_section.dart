import 'package:flutter/material.dart';

import '../../../mock/mock_settings.dart';
import '../../../models/settings.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../theme/palette.dart';
import '../settings_card.dart';

/// 搜索后端。模型侧只看到 `web_search`，具体后端由这里决定（功能协议 §4.3）。
class SearchSection extends StatelessWidget {
  const SearchSection({super.key});

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    return ListenableBuilder(
      listenable: settings,
      builder: (BuildContext context, Widget? _) {
        return SettingsCard(
          title: '搜索后端',
          subtitle: '模型侧只看到 web_search 一个工具，切换后端不改变对话里的调用方式。',
          children: kSearchBackends.map((SearchBackendSpec spec) {
            return _BackendRow(
              spec: spec,
              selected: spec.id == settings.searchBackendId,
              onTap: () => settings.setSearchBackend(spec.id),
            );
          }).toList(),
        );
      },
    );
  }
}

class _BackendRow extends StatelessWidget {
  const _BackendRow({
    required this.spec,
    required this.selected,
    required this.onTap,
  });

  final SearchBackendSpec spec;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: palette.hover,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
                size: 15,
                color: selected ? palette.accent : palette.text3,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    spec.name,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.w500,
                      color: palette.text1,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    spec.desc,
                    style: TextStyle(fontSize: 11, color: palette.text3),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
