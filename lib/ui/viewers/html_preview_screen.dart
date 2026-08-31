import 'package:flutter/material.dart';

import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/toast.dart';

/// HTML 产物预览页。
///
/// 纯前端阶段没有引入 WebView（要保证 Android / Windows 都能直接构建），
/// 这里用原生控件模拟页面渲染，页面区域固定浅色，和应用主题区分开。
/// 正式版会在沙盒 WebView 里加载真实 HTML。
class HtmlPreviewScreen extends StatefulWidget {
  const HtmlPreviewScreen({super.key, required this.file});

  final String file;

  @override
  State<HtmlPreviewScreen> createState() => _HtmlPreviewScreenState();
}

class _HtmlPreviewScreenState extends State<HtmlPreviewScreen> {
  static const List<(String, List<String>)> _sections =
      <(String, List<String>)>[
        ('帐篷与睡眠', <String>['双人帐篷 + 地钉', '防潮垫 ×2', '睡袋（舒适温度 5℃）', '充气枕']),
        ('炊具与食物', <String>['折叠炉头 + 气罐', '钛锅 / 折叠碗筷', '饮用水 4L', '早餐面包、速食汤包']),
        ('衣物与照明', <String>['冲锋衣、速干裤', '备用袜子 2 双', '头灯 + 备用电池', '营地灯']),
        ('安全与杂项', <String>['急救包（含创可贴、药棉）', '驱蚊液', '垃圾袋 3 个', '充电宝 20000mAh']),
      ];

  final Set<String> _checked = <String>{'防潮垫 ×2', '钛锅 / 折叠碗筷'};

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;

    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        toolbarHeight: 50,
        titleSpacing: 4,
        backgroundColor: palette.bgSide,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        title: Row(
          children: <Widget>[
            Expanded(
              child: Text(
                widget.file,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppFonts.mono(size: 12.5, color: palette.text1),
              ),
            ),
            const SizedBox(width: 8),
            const Pill('沙盒', tone: PillTone.good, icon: Icons.shield_outlined),
          ],
        ),
        actions: <Widget>[
          IconAction(
            icon: Icons.open_in_browser,
            tooltip: '用系统浏览器打开',
            onTap: () => showAppToast(context, '外部打开（预览版未接入系统浏览器）'),
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: <Widget>[
            _buildAddressBar(palette),
            Expanded(child: _buildPage()),
            _buildNote(palette),
          ],
        ),
      ),
    );
  }

  Widget _buildAddressBar(AppPalette palette) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      color: palette.bgSide,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: palette.bgRaise,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Row(
                children: <Widget>[
                  Icon(Icons.lock_outline, size: 12, color: palette.text3),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      'sandbox://workspace/${widget.file}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.mono(size: 10.5, color: palette.text2),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 4),
          IconAction(
            icon: Icons.refresh,
            tooltip: '刷新',
            size: 15,
            box: 28,
            onTap: () => setState(_checked.clear),
          ),
        ],
      ),
    );
  }

  /// 页面区域：固定浅色配色，模拟 HTML 自带样式。
  Widget _buildPage() {
    const Color pageBg = Color(0xFFFBF7F0);
    const Color ink = Color(0xFF2B2119);
    const Color accent = Color(0xFF2F7D5B);

    return Container(
      color: pageBg,
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 22),
        children: <Widget>[
          const Text(
            '露营装备清单',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w700,
              color: ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '两天一夜 · 秋季山地营地 · 共 ${_totalItems()} 项',
            style: const TextStyle(fontSize: 12.5, color: Color(0xFF7A6A5B)),
          ),
          const SizedBox(height: 18),
          for (final (String title, List<String> items)
              in _sections) ...<Widget>[
            Row(
              children: <Widget>[
                Container(width: 3, height: 14, color: accent),
                const SizedBox(width: 8),
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: ink,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            for (final String item in items)
              _CheckItem(
                label: item,
                checked: _checked.contains(item),
                accent: accent,
                ink: ink,
                onTap: () => setState(() {
                  if (!_checked.remove(item)) _checked.add(item);
                }),
              ),
            const SizedBox(height: 18),
          ],
        ],
      ),
    );
  }

  int _totalItems() {
    return _sections.fold<int>(
      0,
      (int sum, (String, List<String>) section) => sum + section.$2.length,
    );
  }

  Widget _buildNote(AppPalette palette) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      // 正文是 bg，这条说明用 bgSide，靠色差分开，不画分割线。
      color: palette.bgSide,
      child: Text(
        '预览版用原生控件模拟页面渲染；正式版会在沙盒 WebView 中加载真实 HTML。',
        style: TextStyle(fontSize: 10.5, color: palette.text3),
      ),
    );
  }
}

class _CheckItem extends StatelessWidget {
  const _CheckItem({
    required this.label,
    required this.checked,
    required this.accent,
    required this.ink,
    required this.onTap,
  });

  final String label;
  final bool checked;
  final Color accent;
  final Color ink;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: <Widget>[
            Container(
              width: 16,
              height: 16,
              decoration: BoxDecoration(
                color: checked ? accent : Colors.transparent,
                border: Border.all(
                  color: checked ? accent : const Color(0xFFC7BAA9),
                  width: 1.4,
                ),
                borderRadius: BorderRadius.circular(4),
              ),
              child: checked
                  ? const Icon(Icons.check, size: 12, color: Colors.white)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: checked ? const Color(0xFF9A8C7C) : ink,
                  decoration: checked ? TextDecoration.lineThrough : null,
                  decorationColor: const Color(0xFF9A8C7C),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
