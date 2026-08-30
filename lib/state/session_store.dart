import 'dart:async';

import 'package:flutter/foundation.dart';

import '../mock/mock_reply.dart';
import '../mock/mock_sessions.dart';
import '../models/chat.dart';
import '../models/content.dart';
import '../models/workspace.dart';

/// 会话列表与当前会话的可变状态。
///
/// 纯前端阶段：发送消息后用定时器补一条固定回复，用来验证流式占位、滚动、
/// 中断按钮和列表刷新。接入 Agent Core 后由 agent 事件驱动，这里的定时器删除。
class SessionStore extends ChangeNotifier {
  SessionStore({
    List<ChatSession> initial = kMockSessions,
    this.replyDelay = const Duration(milliseconds: 900),
  }) : assert(initial.length > 0, '至少需要一个初始会话'), // ignore: prefer_is_empty
       _sessions = List<ChatSession>.of(initial),
       _activeId = initial.first.id,
       _nextSeq = initial.length + 1;

  /// 假回复的延迟，测试里可以传 [Duration.zero]。
  final Duration replyDelay;

  List<ChatSession> _sessions;
  String _activeId;
  int _nextSeq;
  Timer? _replyTimer;
  String? _streamingMessageId;

  List<ChatSession> get sessions => List<ChatSession>.unmodifiable(_sessions);
  String get activeId => _activeId;
  bool get isGenerating => _streamingMessageId != null;

  ChatSession get active {
    return _sessions.firstWhere((ChatSession s) => s.id == _activeId);
  }

  void select(String id) {
    if (_activeId == id) return;
    if (_sessions.every((ChatSession s) => s.id != id)) {
      throw ArgumentError.value(id, 'id', '会话不存在');
    }
    _cancelReply();
    _activeId = id;
    notifyListeners();
  }

  /// 新建空会话并切换过去。[model] 由调用方从设置里取默认模型。
  ChatSession createSession({required String model}) {
    _cancelReply();
    final ChatSession session = ChatSession(
      id: 's${_nextSeq++}',
      title: '新会话',
      group: '今天',
      time: _clock(),
      preview: '还没有消息',
      model: model,
      files: const <WorkspaceFile>[],
      messages: const <ChatMessage>[],
    );
    _sessions = <ChatSession>[session, ..._sessions];
    _activeId = session.id;
    notifyListeners();
    return session;
  }

  /// 删除会话；删掉最后一个时补一个空会话，保证 [active] 始终有值。
  void deleteSession(String id, {required String fallbackModel}) {
    if (_sessions.every((ChatSession s) => s.id != id)) {
      throw ArgumentError.value(id, 'id', '会话不存在');
    }
    if (id == _activeId) _cancelReply();
    _sessions = _sessions.where((ChatSession s) => s.id != id).toList();
    if (_sessions.isEmpty) {
      createSession(model: fallbackModel);
      return;
    }
    if (id == _activeId) _activeId = _sessions.first.id;
    notifyListeners();
  }

  void renameSession(String id, String title) {
    final String trimmed = title.trim();
    if (trimmed.isEmpty) return;
    _replace(id, (ChatSession s) => s.copyWith(title: trimmed));
  }

  void setModel(String id, String model) {
    _replace(id, (ChatSession s) => s.copyWith(model: model));
  }

  /// 追加用户消息，并排入一条占位的助手消息。
  void sendMessage(String text) {
    final String trimmed = text.trim();
    if (trimmed.isEmpty) return;
    _cancelReply();

    final ChatSession session = active;
    final String time = _clock();
    final String userId = '${session.id}-u${session.messages.length + 1}';
    final String replyId = '${session.id}-a${session.messages.length + 2}';
    final ChatMessage userMessage = ChatMessage(
      id: userId,
      isUser: true,
      time: time,
      blocks: <ContentBlock>[ParagraphBlock(trimmed)],
    );

    _streamingMessageId = replyId;
    _replace(
      session.id,
      (ChatSession s) => s.copyWith(
        title: s.messages.isEmpty ? _titleFrom(trimmed) : s.title,
        preview: trimmed,
        time: time,
        messages: <ChatMessage>[
          ...s.messages,
          userMessage,
          MockReply.placeholder(id: replyId, time: time),
        ],
      ),
    );

    _replyTimer = Timer(replyDelay, () {
      _replyTimer = null;
      _finishReply(session.id, replyId, trimmed);
    });
  }

  /// 用户主动中断生成：保留已产生的占位消息文案，不伪造完整结果。
  void stopGenerating() {
    final String? replyId = _streamingMessageId;
    if (replyId == null) return;
    _cancelReply();
    _replace(active.id, (ChatSession s) {
      return s.copyWith(
        messages: s.messages
            .map(
              (ChatMessage m) => m.id == replyId
                  ? m.copyWith(
                      isStreaming: false,
                      blocks: <ContentBlock>[ParagraphBlock('已中断本次生成。')],
                    )
                  : m,
            )
            .toList(),
      );
    });
  }

  void _finishReply(String sessionId, String replyId, String userText) {
    if (_streamingMessageId != replyId) return;
    _streamingMessageId = null;
    final ChatMessage reply = MockReply.complete(
      id: replyId,
      time: _clock(),
      userText: userText,
    );
    _replace(sessionId, (ChatSession s) {
      return s.copyWith(
        messages: s.messages
            .map((ChatMessage m) => m.id == replyId ? reply : m)
            .toList(),
      );
    });
  }

  void _replace(String id, ChatSession Function(ChatSession) update) {
    final int index = _sessions.indexWhere((ChatSession s) => s.id == id);
    if (index < 0) throw ArgumentError.value(id, 'id', '会话不存在');
    _sessions = List<ChatSession>.of(_sessions)
      ..[index] = update(_sessions[index]);
    notifyListeners();
  }

  void _cancelReply() {
    _replyTimer?.cancel();
    _replyTimer = null;
    _streamingMessageId = null;
  }

  /// 会话标题取用户第一句话的前几个字（功能协议 §2.1）。
  static String _titleFrom(String text) {
    final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
  }

  static String _clock() {
    final DateTime now = DateTime.now();
    final String hh = now.hour.toString().padLeft(2, '0');
    final String mm = now.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }

  @override
  void dispose() {
    _cancelReply();
    super.dispose();
  }
}
