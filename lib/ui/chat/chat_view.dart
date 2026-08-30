import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/responsive.dart';
import '../../models/chat.dart';
import '../../state/app_scope.dart';
import '../../state/session_store.dart';
import '../../theme/palette.dart';
import 'chat_header.dart';
import 'composer.dart';
import 'message_item.dart';

/// 中间聊天栏：顶栏 + 消息流 + 输入区。
class ChatView extends StatefulWidget {
  const ChatView({super.key, this.onOpenSessions, this.onOpenWorkspace});

  /// 窄屏外壳传入，用于打开左右抽屉；宽屏为 null。
  final VoidCallback? onOpenSessions;
  final VoidCallback? onOpenWorkspace;

  @override
  State<ChatView> createState() => _ChatViewState();
}

class _ChatViewState extends State<ChatView> {
  final ScrollController _scroll = ScrollController();

  /// 上一次渲染的「会话 + 消息数 + 是否生成中」，用于判断要不要滚到底部。
  String _signature = '';

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _scheduleScrollToBottom(ChatSession session, bool generating) {
    final String signature =
        '${session.id}|${session.messages.length}|$generating';
    if (signature == _signature) return;
    final bool sameSession = _signature.startsWith('${session.id}|');
    _signature = signature;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!_scroll.hasClients) return;
      final double target = _scroll.position.maxScrollExtent;
      if (sameSession) {
        unawaited(
          _scroll.animateTo(
            target,
            duration: const Duration(milliseconds: 240),
            curve: Curves.easeOut,
          ),
        );
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final SessionStore store = context.sessions;
    return ListenableBuilder(
      listenable: store,
      builder: (BuildContext context, Widget? _) {
        final ChatSession session = store.active;
        _scheduleScrollToBottom(session, store.isGenerating);

        return Container(
          color: context.palette.bg,
          child: Column(
            children: <Widget>[
              ChatHeader(
                session: session,
                onOpenSessions: widget.onOpenSessions,
                onOpenWorkspace: widget.onOpenWorkspace,
              ),
              Expanded(
                child: session.messages.isEmpty
                    ? const _EmptyState()
                    : _buildList(context, session),
              ),
              Composer(
                isGenerating: store.isGenerating,
                onSend: store.sendMessage,
                onStop: store.stopGenerating,
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildList(BuildContext context, ChatSession session) {
    final bool compact = isCompact(context);
    final List<String> gallery = <String>[
      for (final ChatMessage message in session.messages)
        for (final ImageResult image in message.images) image.file,
    ];

    return ListView.separated(
      controller: _scroll,
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 14 : 20,
        vertical: 18,
      ),
      itemCount: session.messages.length,
      separatorBuilder: (BuildContext _, int _) => const SizedBox(height: 22),
      itemBuilder: (BuildContext context, int index) {
        return Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SizedBox(
              width: double.infinity,
              child: MessageItemView(
                message: session.messages[index],
                gallery: gallery,
              ),
            ),
          ),
        );
      },
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.forum_outlined, size: 34, color: palette.text3),
          const SizedBox(height: 12),
          Text(
            '有什么可以帮忙的？',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: palette.text1,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '本地优先 · 文件与脚本工具会先征求你的同意',
            style: TextStyle(fontSize: 12, color: palette.text3),
          ),
        ],
      ),
    );
  }
}
