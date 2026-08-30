import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/models/chat.dart';
import 'package:wepchat/models/workspace.dart';
import 'package:wepchat/state/session_store.dart';

/// 一个最小会话，避免测试依赖 mock 数据的具体内容。
ChatSession _emptySession(String id) {
  return ChatSession(
    id: id,
    title: '新会话',
    group: '今天',
    time: '09:00',
    preview: '还没有消息',
    model: 'gpt-4o',
    files: const <WorkspaceFile>[],
    messages: const <ChatMessage>[],
  );
}

void main() {
  SessionStore build() {
    return SessionStore(
      initial: <ChatSession>[_emptySession('s1'), _emptySession('s2')],
      replyDelay: Duration.zero,
    );
  }

  test('发送消息后追加用户消息与占位回复，并进入生成中', () {
    final SessionStore store = build();
    addTearDown(store.dispose);

    store.sendMessage('帮我整理一下 Q2 销售数据');

    expect(store.active.messages.length, 2);
    expect(store.active.messages.first.isUser, isTrue);
    expect(store.active.messages.last.isStreaming, isTrue);
    expect(store.isGenerating, isTrue);
    // 标题取用户第一句话的前几个字（功能协议 §2.1）。
    expect(store.active.title, '帮我整理一下 Q2 销售数据');
  });

  test('延迟结束后回复完成，不再是流式状态', () async {
    final SessionStore store = build();
    addTearDown(store.dispose);

    store.sendMessage('你好');
    await Future<void>.delayed(const Duration(milliseconds: 16));

    expect(store.isGenerating, isFalse);
    expect(store.active.messages.last.isStreaming, isFalse);
  });

  test('中断生成保留占位消息，不伪造完整结果', () {
    final SessionStore store = build();
    addTearDown(store.dispose);

    store.sendMessage('写一份报告');
    store.stopGenerating();

    expect(store.isGenerating, isFalse);
    expect(store.active.messages.last.isStreaming, isFalse);
  });

  test('切换会话会取消上一个会话的生成', () {
    final SessionStore store = build();
    addTearDown(store.dispose);

    store.sendMessage('你好');
    store.select('s2');

    expect(store.isGenerating, isFalse);
    expect(store.activeId, 's2');
  });

  test('删除最后一个会话时补一个空会话，active 始终有值', () {
    final SessionStore store = build();
    addTearDown(store.dispose);

    store.deleteSession('s1', fallbackModel: 'gpt-4o');
    store.deleteSession('s2', fallbackModel: 'gpt-4o');

    expect(store.sessions.length, 1);
    expect(store.active.messages, isEmpty);
  });

  test('操作不存在的会话会抛错，而不是静默忽略', () {
    final SessionStore store = build();
    addTearDown(store.dispose);

    expect(() => store.select('nope'), throwsArgumentError);
    expect(
      () => store.deleteSession('nope', fallbackModel: 'gpt-4o'),
      throwsArgumentError,
    );
  });
}
