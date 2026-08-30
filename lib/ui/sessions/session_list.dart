import 'package:flutter/material.dart';

import '../../app/app_nav.dart';
import '../../mock/mock_sessions.dart';
import '../../models/chat.dart';
import '../../state/app_scope.dart';
import '../../state/session_store.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';

/// 左侧会话列表：搜索、按时间分组、底部记忆与设置入口。
class SessionListPanel extends StatefulWidget {
  const SessionListPanel({
    super.key,
    this.onNavigate,
    this.onCollapse,
    this.collapseIcon,
  });

  /// 选中或新建会话后回调，窄屏用来关闭抽屉。
  final VoidCallback? onNavigate;

  /// 收起面板（宽屏）或关闭抽屉（窄屏）；为 null 时不显示该按钮。
  final VoidCallback? onCollapse;
  final IconData? collapseIcon;

  @override
  State<SessionListPanel> createState() => _SessionListPanelState();
}

class _SessionListPanelState extends State<SessionListPanel> {
  final TextEditingController _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final SessionStore store = context.sessions;

    return Container(
      color: palette.bgSide,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _buildHeader(context, store),
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: _buildSearch(palette),
            ),
            Expanded(
              child: ListenableBuilder(
                listenable: store,
                builder: (BuildContext context, Widget? _) {
                  return _buildList(context, store);
                },
              ),
            ),
            _buildFooter(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, SessionStore store) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              'WePChat',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.2,
                color: palette.text1,
              ),
            ),
          ),
          IconAction(
            icon: Icons.add,
            tooltip: '新建会话',
            onTap: () {
              store.createSession(model: context.settings.defaultModel);
              widget.onNavigate?.call();
            },
          ),
          if (widget.onCollapse != null)
            IconAction(
              icon: widget.collapseIcon ?? Icons.chevron_left,
              tooltip: '收起会话列表',
              onTap: widget.onCollapse!,
            ),
        ],
      ),
    );
  }

  Widget _buildSearch(AppPalette palette) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.search, size: 15, color: palette.text3),
          const SizedBox(width: 6),
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: (String value) =>
                  setState(() => _query = value.trim()),
              style: TextStyle(fontSize: 12.5, color: palette.text1),
              cursorColor: palette.accent,
              decoration: InputDecoration(
                isDense: true,
                filled: false,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                hintText: '搜索会话',
                hintStyle: TextStyle(fontSize: 12.5, color: palette.text3),
              ),
            ),
          ),
          if (_query.isNotEmpty)
            IconAction(
              icon: Icons.close,
              tooltip: '清除',
              size: 13,
              box: 22,
              onTap: () {
                _search.clear();
                setState(() => _query = '');
              },
            ),
        ],
      ),
    );
  }

  Widget _buildList(BuildContext context, SessionStore store) {
    final List<ChatSession> matched = store.sessions.where(_matches).toList();
    if (matched.isEmpty) {
      return Center(
        child: Text(
          '无结果',
          style: TextStyle(fontSize: 12, color: context.palette.text3),
        ),
      );
    }

    final List<Widget> children = <Widget>[];
    for (final String group in kSessionGroupOrder) {
      final List<ChatSession> inGroup = matched
          .where((ChatSession s) => s.group == group)
          .toList();
      if (inGroup.isEmpty) continue;
      children.add(
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
          child: SectionLabel(group),
        ),
      );
      for (final ChatSession session in inGroup) {
        children.add(
          _SessionRow(
            session: session,
            selected: session.id == store.activeId,
            onTap: () {
              store.select(session.id);
              widget.onNavigate?.call();
            },
          ),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 8),
      children: children,
    );
  }

  bool _matches(ChatSession session) {
    if (_query.isEmpty) return true;
    final String needle = _query.toLowerCase();
    return session.title.toLowerCase().contains(needle) ||
        session.preview.toLowerCase().contains(needle);
  }

  Widget _buildFooter(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: palette.border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: _FooterButton(
              icon: Icons.psychology_alt_outlined,
              label: '记忆',
              onTap: () {
                widget.onNavigate?.call();
                AppNav.openSettings(context, sectionId: 'memory');
              },
            ),
          ),
          Expanded(
            child: _FooterButton(
              icon: Icons.settings_outlined,
              label: '设置',
              onTap: () {
                widget.onNavigate?.call();
                AppNav.openSettings(context);
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _SessionRow extends StatelessWidget {
  const _SessionRow({
    required this.session,
    required this.selected,
    required this.onTap,
  });

  final ChatSession session;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        hoverColor: palette.hover,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? palette.active : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      session.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: palette.text1,
                      ),
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    session.time,
                    style: TextStyle(fontSize: 10, color: palette.text3),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                session.preview,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11, color: palette.text3),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FooterButton extends StatelessWidget {
  const _FooterButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      hoverColor: palette.hover,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            Icon(icon, size: 15, color: palette.text2),
            const SizedBox(width: 6),
            Text(label, style: TextStyle(fontSize: 12, color: palette.text2)),
          ],
        ),
      ),
    );
  }
}
