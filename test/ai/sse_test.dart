import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/sse.dart';

/// 把字符串切成指定大小的块，模拟网络分片。
Stream<List<int>> chunked(String text, {int size = 8}) async* {
  final List<int> bytes = utf8.encode(text);
  for (int i = 0; i < bytes.length; i += size) {
    yield bytes.sublist(i, (i + size).clamp(0, bytes.length));
  }
}

Stream<List<int>> single(String text) async* {
  yield utf8.encode(text);
}

void main() {
  group('SSE 基础解析', () {
    test('单个事件', () async {
      final List<SseEvent> events =
          await parseSse(single('data: hello\n\n')).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('hello'));
      expect(events[0].event, isNull);
    });

    test('多个事件', () async {
      final List<SseEvent> events = await parseSse(
        single('data: one\n\ndata: two\n\ndata: three\n\n'),
      ).toList();

      expect(events.map((SseEvent e) => e.data).toList(),
          equals(<String>['one', 'two', 'three']));
    });

    test('带 event 字段', () async {
      final List<SseEvent> events = await parseSse(
        single('event: content_block_delta\ndata: {"x":1}\n\n'),
      ).toList();

      expect(events.length, equals(1));
      expect(events[0].event, equals('content_block_delta'));
      expect(events[0].data, equals('{"x":1}'));
    });

    test('多行 data 用 \\n 连接', () async {
      final List<SseEvent> events = await parseSse(
        single('data: line1\ndata: line2\ndata: line3\n\n'),
      ).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('line1\nline2\nline3'));
    });

    test('[DONE] 标记', () async {
      final List<SseEvent> events = await parseSse(
        single('data: {"x":1}\n\ndata: [DONE]\n\n'),
      ).toList();

      expect(events.length, equals(2));
      expect(events[0].isDone, isFalse);
      expect(events[1].isDone, isTrue);
    });
  });

  group('SSE 边界情况', () {
    test('注释行被忽略', () async {
      final List<SseEvent> events = await parseSse(
        single(': this is a keepalive\ndata: real\n\n'),
      ).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('real'));
    });

    test('只有注释不产生事件', () async {
      final List<SseEvent> events =
          await parseSse(single(': ping\n\n: ping\n\n')).toList();

      expect(events, isEmpty);
    });

    test('CRLF 行尾', () async {
      final List<SseEvent> events = await parseSse(
        single('data: hello\r\n\r\ndata: world\r\n\r\n'),
      ).toList();

      expect(events.map((SseEvent e) => e.data).toList(),
          equals(<String>['hello', 'world']));
    });

    test('冒号后只去掉一个空格', () async {
      final List<SseEvent> events =
          await parseSse(single('data:  two spaces\n\n')).toList();

      expect(events[0].data, equals(' two spaces'));
    });

    test('无冒号的行被忽略', () async {
      final List<SseEvent> events = await parseSse(
        single('garbage\ndata: real\n\n'),
      ).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('real'));
    });

    test('只有 event 没有 data 不产生事件', () async {
      final List<SseEvent> events =
          await parseSse(single('event: ping\n\ndata: real\n\n')).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('real'));
      expect(events[0].event, isNull);
    });

    test('结尾缺少空行仍产生事件', () async {
      final List<SseEvent> events =
          await parseSse(single('data: no trailing newline')).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('no trailing newline'));
    });

    test('id 与 retry 字段被忽略', () async {
      final List<SseEvent> events = await parseSse(
        single('id: 42\nretry: 3000\ndata: real\n\n'),
      ).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('real'));
    });
  });

  group('SSE 跨块边界', () {
    test('事件被切成小块', () async {
      final List<SseEvent> events = await parseSse(
        chunked('data: hello world\n\ndata: second event\n\n', size: 3),
      ).toList();

      expect(events.map((SseEvent e) => e.data).toList(),
          equals(<String>['hello world', 'second event']));
    });

    test('UTF-8 多字节被切在块边界', () async {
      // 中文每字 3 字节，块大小 2 保证一定切断
      const String text = 'data: 你好世界，这是一段中文\n\n';
      final List<SseEvent> events =
          await parseSse(chunked(text, size: 2)).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('你好世界，这是一段中文'));
    });

    test('CRLF 被切在块边界', () async {
      // 精确构造：让 \r 是某块的最后一个字节
      final List<List<int>> chunks = <List<int>>[
        utf8.encode('data: a\r'),
        utf8.encode('\n\r\n'),
      ];
      final List<SseEvent> events =
          await parseSse(Stream<List<int>>.fromIterable(chunks)).toList();

      expect(events.length, equals(1));
      expect(events[0].data, equals('a'));
    });

    test('每字节一块', () async {
      final List<SseEvent> events = await parseSse(
        chunked('event: e1\ndata: abc\n\nevent: e2\ndata: def\n\n', size: 1),
      ).toList();

      expect(events.length, equals(2));
      expect(events[0].event, equals('e1'));
      expect(events[0].data, equals('abc'));
      expect(events[1].event, equals('e2'));
      expect(events[1].data, equals('def'));
    });
  });

  group('SSE 真实响应片段', () {
    test('anthropic 的 content_block 序列', () async {
      const String raw = '''
event: message_start
data: {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":10}}}

event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Hi"}}

event: message_stop
data: {"type":"message_stop"}

''';
      final List<SseEvent> events = await parseSse(chunked(raw, size: 7)).toList();

      expect(events.length, equals(4));
      expect(events[0].event, equals('message_start'));
      expect(events[2].event, equals('content_block_delta'));
      expect(events[2].data, contains('"text":"Hi"'));
    });

    test('openai 的 choices/delta 序列', () async {
      const String raw = '''
data: {"choices":[{"delta":{"content":"Hello"},"index":0}]}

data: {"choices":[{"delta":{"content":" world"},"index":0}]}

data: [DONE]

''';
      final List<SseEvent> events = await parseSse(chunked(raw, size: 11)).toList();

      expect(events.length, equals(3));
      expect(events[0].event, isNull);
      expect(events[2].isDone, isTrue);
    });
  });
}
