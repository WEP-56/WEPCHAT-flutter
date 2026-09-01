/// 共享的 SSE 解析器（实施 TODO §4-4）。
///
/// 三个适配器都用这一个，绝不写三份行拆分逻辑（AGENTS.md §1.2）。
/// 各家的差异在**事件体的 JSON 结构**上，不在 SSE 的传输格式上——
/// 传输格式是 W3C 规范，一份就够。
library;

import 'dart:async';
import 'dart:convert';

/// 一个 SSE 事件。
///
/// [event] 是 `event:` 字段（anthropic 用它区分 `content_block_delta`
/// 之类；openai-completions 不发这个字段，永远是 null）。
/// [data] 是 `data:` 字段拼起来的内容——多行 `data:` 要用 `\n` 连接，
/// 这是规范要求，不是可选项。
class SseEvent {
  const SseEvent({required this.data, this.event});

  final String data;
  final String? event;

  /// `data: [DONE]` 是 openai 的流结束标记，不是 JSON。
  bool get isDone => data == '[DONE]';

  @override
  String toString() => 'SseEvent(event: $event, data: ${data.length} chars)';
}

/// 把字节流解析成 SSE 事件流。
///
/// 处理的边界情况（每一条都真实出现过）：
/// - UTF-8 多字节字符被切在块边界 → 用 `utf8.decoder` 带状态解码，
///   不能对每个块单独 `utf8.decode`
/// - 一行被切在块边界 → 缓冲未完成的行
/// - 多行 `data:` → 用 `\n` 连接
/// - 注释行（以 `:` 开头）→ 忽略，这是服务端的保活心跳
/// - `\r\n` 与 `\n` 混用 → 都当行尾
/// - 事件以空行结束 → 空行才 emit，不是每行都 emit
Stream<SseEvent> parseSse(Stream<List<int>> byteStream) {
  return byteStream
      .transform(utf8.decoder)
      .transform(const _SseLineSplitter())
      .transform(const _SseEventAssembler());
}

/// 按行拆分，处理跨块的半行。
///
/// 不用 `const LineSplitter()`：它按 `\r`、`\n`、`\r\n` 都拆，而 SSE
/// 里单独的 `\r` 也算行尾——行为恰好一致，但 LineSplitter 不保证跨
/// chunk 的状态语义在未来版本不变，这里自己拆更稳。
class _SseLineSplitter extends StreamTransformerBase<String, String> {
  const _SseLineSplitter();

  @override
  Stream<String> bind(Stream<String> stream) {
    return Stream<String>.eventTransformed(
      stream,
      (EventSink<String> sink) => _SseLineSink(sink),
    );
  }
}

class _SseLineSink implements EventSink<String> {
  _SseLineSink(this._out);

  final EventSink<String> _out;
  final StringBuffer _partial = StringBuffer();

  /// 上一块是否以 `\r` 结尾——`\r\n` 被切开时不能当成两个行尾。
  bool _pendingCr = false;

  @override
  void add(String chunk) {
    for (int i = 0; i < chunk.length; i++) {
      final String ch = chunk[i];

      if (_pendingCr) {
        _pendingCr = false;
        // `\r\n`：`\r` 已经触发过行尾，这里的 `\n` 直接吃掉。
        if (ch == '\n') continue;
      }

      if (ch == '\n') {
        _flushLine();
      } else if (ch == '\r') {
        _flushLine();
        _pendingCr = true;
      } else {
        _partial.write(ch);
      }
    }
  }

  void _flushLine() {
    _out.add(_partial.toString());
    _partial.clear();
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _out.addError(error, stackTrace);
  }

  @override
  void close() {
    // 流结束时缓冲里还有内容：服务端没发最后的换行。当成完整一行处理，
    // 丢掉它会丢掉最后一个事件。
    if (_partial.isNotEmpty) _flushLine();
    _out.close();
  }
}

/// 把行组装成事件。空行是事件边界。
class _SseEventAssembler extends StreamTransformerBase<String, SseEvent> {
  const _SseEventAssembler();

  @override
  Stream<SseEvent> bind(Stream<String> stream) {
    return Stream<SseEvent>.eventTransformed(
      stream,
      (EventSink<SseEvent> sink) => _SseEventSink(sink),
    );
  }
}

class _SseEventSink implements EventSink<String> {
  _SseEventSink(this._out);

  final EventSink<SseEvent> _out;
  final List<String> _dataLines = <String>[];
  String? _eventName;

  @override
  void add(String line) {
    // 空行：事件结束。
    if (line.isEmpty) {
      _emit();
      return;
    }

    // 注释行：服务端保活心跳，忽略。
    if (line.startsWith(':')) return;

    final int colon = line.indexOf(':');
    if (colon < 0) {
      // 无冒号的行按规范是"字段名 + 空值"，我们关心的字段都要值，忽略。
      return;
    }

    final String field = line.substring(0, colon);
    // 冒号后的单个空格要去掉，再往后的空格保留——规范如此，
    // 且 `data:  {…}` 里第二个空格属于内容。
    String value = line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);

    switch (field) {
      case 'data':
        _dataLines.add(value);
      case 'event':
        _eventName = value;
      // `id` / `retry` 我们不用：不做断线重连（重试策略见 §4-10，
      // 首字节到达后不重试，所以 Last-Event-ID 没有意义）。
    }
  }

  void _emit() {
    if (_dataLines.isEmpty) {
      // 只有 event: 没有 data: 的事件没有内容，丢掉。
      _eventName = null;
      return;
    }
    _out.add(SseEvent(data: _dataLines.join('\n'), event: _eventName));
    _dataLines.clear();
    _eventName = null;
  }

  @override
  void addError(Object error, [StackTrace? stackTrace]) {
    _out.addError(error, stackTrace);
  }

  @override
  void close() {
    // 服务端没发结尾空行时，最后一个事件还在缓冲里。
    _emit();
    _out.close();
  }
}
