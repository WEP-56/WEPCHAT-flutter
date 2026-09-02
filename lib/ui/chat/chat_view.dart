import 'dart:async';

import 'package:flutter/material.dart';

import '../../app/responsive.dart';
import '../../models/chat.dart';
import '../../state/app_scope.dart';
import '../../state/session_store.dart';
import '../../theme/palette.dart';
import '../widgets/toast.dart';
import 'chat_header.dart';
import 'composer.dart';
import 'message_item.dart';
import 'usage_bar.dart';

/// 中间聊天栏：顶栏 + 消息流 + 输入区。
class ChatView extends StatefulWidget {
  const ChatView({
    super.key,
    this.onOpenSessions,
    this.onToggleWorkspace,
    this.workspaceOpen = false,
  });

  /// 窄屏外壳传入，用于打开左抽屉；宽屏为 null。
  final VoidCallback? onOpenSessions;

  /// 工作区开关：窄屏开右抽屉，宽屏收起 / 展开右栏。
  final VoidCallback? onToggleWorkspace;
  final bool workspaceOpen;

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

  /// 生成中「算作还在跟读」的距底距离。
  ///
  /// 每个 delta 只长一点点，跟着读的人离底部不会超过一行；这个阈值一旦调大，
  /// 往上翻两行看历史就会被拽回去。
  static const double _kFollowSlack = 120;

  void _scheduleScrollToBottom(ChatSession session, bool generating) {
    // 在 build 里读位置：此刻 position 还是上一帧的布局结果，所以能判断
    // 「新内容进来之前用户是不是贴着底部」。放到 postFrame 里读就晚了——
    // 那时 maxScrollExtent 已经被新内容撑大，看起来永远像是离底很远。
    final bool following = !_scroll.hasClients ||
        _scroll.position.maxScrollExtent - _scroll.position.pixels <
            _kFollowSlack;

    final String signature =
        '${session.id}|${session.messages.length}|$generating';
    final bool changed = signature != _signature;
    // 生成中即使 signature 不变也要跟：流式文字在同一条消息里长，
    // 消息数不动，光看 signature 是看不出内容变多了的。
    if (!changed && !generating) return;

    final bool sameSession = _signature.startsWith('${session.id}|');
    _signature = signature;

    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!_scroll.hasClients) return;
      final double target = _scroll.position.maxScrollExtent;

      if (generating) {
        // 打字过程中不用动画：240ms 的动画还没走完下一个 delta 就来了，
        // 结果是一直在半路上抖。
        if (following) _scroll.jumpTo(target);
        return;
      }
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

  /// 把 store 攒下的一次性提示显示出来。
  ///
  /// 没配 key、模型被删这类失败不进对话记录（那是设置问题，不是聊天内容），
  /// 所以只能走 toast。build 里取走、postFrame 里显示——SnackBar 不能在
  /// build 期间插进 Overlay。
  void _showNotice(SessionStore store) {
    final String? notice = store.takeNotice();
    if (notice == null) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      showAppToast(context, notice);
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
        _showNotice(store);

        return Container(
          color: context.palette.bg,
          child: Column(
            children: <Widget>[
              ChatHeader(
                session: session,
                onOpenSessions: widget.onOpenSessions,
                onToggleWorkspace: widget.onToggleWorkspace,
                workspaceOpen: widget.workspaceOpen,
              ),
              Expanded(
                child: session.messages.isEmpty
                    ? const _EmptyState()
                    : _buildList(context, session),
              ),
              if (store.activeWasInterrupted)
                _InterruptedBanner(
                  onDismiss: () => store.clearInterrupted(session.id),
                ),
              UsageBar(usage: store.lastUsage),
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
      // 不给 item 加语义索引：`IndexedSemantics` 会把一条消息合并成一个语义节点，
      // 连带并进它里面多个 Tooltip 的 OverlayPortal 锚点（图片卡片的「导出 / 查看」、
      // 多个代码块的「复制代码」）。上游 flutter#182444 在这种情况下只保留第一个
      // 锚点的遍历标识，Windows 的 accessibility bridge 于是在滚动时不停报
      // `Failed to update ui::AXTree`。消息列表要保持懒加载，只能关掉索引。
      addSemanticIndexes: false,
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

/// 「上次回复被中断」提示条（实施 TODO §10-6，存储设计 §6.2）。
///
/// 只提示不自动重发（§13.5 已定）：用户可能就是故意杀掉的，替他重发一次
/// 要花钱。重发就是再打一遍——不给按钮，因为上次那条用户消息还在历史里，
/// 用户自己看得见。
class _InterruptedBanner extends StatelessWidget {
  const _InterruptedBanner({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(20, 0, 20, 6),
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(
        color: palette.bgRaise,
        border: Border.all(color: palette.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: <Widget>[
          Icon(Icons.history_toggle_off, size: 15, color: palette.text3),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '上次的回复没有正常结束，可以再发一次消息继续。',
              style: TextStyle(fontSize: 11.5, color: palette.text2),
            ),
          ),
          IconButton(
            onPressed: onDismiss,
            icon: const Icon(Icons.close, size: 15),
            color: palette.text3,
            visualDensity: VisualDensity.compact,
            tooltip: '知道了',
          ),
        ],
      ),
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
