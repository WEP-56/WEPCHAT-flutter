part of 'session_store.dart';

/// 把存储记录投影成聊天界面使用的只读模型。
ChatSession _toChatSession(SessionRecord record, List<EntryRecord> entries) {
  return ChatSession(
    id: record.id,
    title: record.title,
    group: _groupLabel(record.updatedAt),
    time: _timeLabel(record.updatedAt),
    preview: record.preview.isEmpty ? '还没有消息' : record.preview,
    model: record.modelId,
    thinking: record.thinking,
    files: const <WorkspaceFile>[],
    messages: _toChatMessages(entries),
  );
}

/// 条目列表 → 气泡列表。工具结果挂到紧邻的下一条助手消息上。
List<ChatMessage> _toChatMessages(List<EntryRecord> entries) {
  final List<ChatMessage> out = <ChatMessage>[];
  final List<ToolCall> pending = <ToolCall>[];

  for (final EntryRecord entry in applyTruncations(entries)) {
    if (entry.type != EntryType.message) continue;
    if (entry.role == EntryRole.toolResult) {
      pending.add(_toToolCall(entry));
      continue;
    }

    final ChatMessage message = _toChatMessage(entry);
    if (pending.isEmpty || entry.role == EntryRole.user) {
      if (pending.isNotEmpty) {
        out.add(_toolOnlyMessage(pending));
        pending.clear();
      }
      out.add(message);
      continue;
    }

    out.add(message.copyWith(tools: List<ToolCall>.of(pending)));
    pending.clear();
  }

  if (pending.isNotEmpty) out.add(_toolOnlyMessage(pending));
  return out;
}

ChatMessage _toolOnlyMessage(List<ToolCall> tools) {
  return ChatMessage(
    id: tools.first.id,
    role: ChatRole.toolResult,
    time: '',
    tools: List<ToolCall>.of(tools),
  );
}

ToolCall _toToolCall(EntryRecord entry) {
  final String name = entry.payload['name'] as String? ?? '未知工具';
  final String content = entry.payload['content'] as String? ?? '';
  final String outcome = entry.payload['outcome'] as String? ?? 'ok';
  final Object? rawArgs = entry.payload['arguments'];
  final Map<String, Object?> arguments = rawArgs is Map
      ? <String, Object?>{
          for (final MapEntry<Object?, Object?> item in rawArgs.entries)
            if (item.key is String) item.key as String: item.value,
        }
      : const <String, Object?>{};
  final ToolOutcome parsedOutcome = switch (outcome) {
    'failed' => ToolOutcome.failed,
    'cancelled' => ToolOutcome.cancelled,
    'denied' => ToolOutcome.denied,
    _ => ToolOutcome.ok,
  };
  final Object? rawUi = entry.payload['ui'];
  final Map<String, Object?>? ui = rawUi is Map
      ? <String, Object?>{
          for (final MapEntry<Object?, Object?> item in rawUi.entries)
            if (item.key is String) item.key as String: item.value,
        }
      : null;
  return restoredToolCall(
    id: entry.id,
    name: name,
    arguments: arguments,
    content: content,
    outcome: parsedOutcome,
    uiPayload: ui,
  );
}

ChatMessage _toChatMessage(EntryRecord entry) {
  final bool isUser = entry.role == EntryRole.user;
  final String text = entry.payload['text'] as String? ?? '';
  final int? elapsedMs = entry.payload['elapsedMs'] as int?;
  final List<Attachment> attachments = <Attachment>[];
  final Object? rawAttachments = entry.payload['attachments'];
  if (rawAttachments is List) {
    for (final Object? raw in rawAttachments) {
      if (raw is! Map<String, Object?> || raw['name'] is! String) continue;
      final String name = raw['name'] as String;
      final String mime = raw['mimeType'] as String? ?? '';
      final String? base64 = raw['base64'] as String?;
      final FileKind kind = mime.startsWith('image/')
          ? FileKind.png
          : FileKind.txt;
      attachments.add(
        Attachment(
          name: name,
          size: '附件',
          kind: kind,
          base64Data: base64,
          mimeType: mime,
        ),
      );
    }
  }

  return ChatMessage(
    id: entry.id,
    role: isUser ? ChatRole.user : ChatRole.assistant,
    time: _timeLabel(entry.createdAt),
    seq: entry.seq,
    attachments: attachments,
    rawText: text,
    usage: isUser ? null : _usageOf(entry),
    elapsed: elapsedMs == null ? null : Duration(milliseconds: elapsedMs),
    blocks: isUser
        ? (text.isEmpty
              ? const <ContentBlock>[]
              : <ContentBlock>[ParagraphBlock(text)])
        : _blocksOf(
            text: text,
            thinking: entry.payload['thinking'] as String? ?? '',
            error: entry.payload['error'] as String?,
          ),
  );
}

MessageUsage? _usageOf(EntryRecord entry) {
  final TokenUsage usage = entry.usage;
  final int reasoning = entry.payload['reasoningTokens'] as int? ?? 0;
  if (usage.isEmpty && reasoning == 0) return null;
  return MessageUsage(
    inputTokens: usage.inputTokens ?? 0,
    outputTokens: usage.outputTokens ?? 0,
    cacheReadTokens: usage.cacheReadTokens ?? 0,
    cacheWriteTokens: usage.cacheWriteTokens ?? 0,
    reasoningTokens: reasoning,
  );
}

List<ContentBlock> _blocksOf({
  required String text,
  required String thinking,
  required String? error,
}) {
  return <ContentBlock>[
    if (thinking.isNotEmpty) ThinkingBlock(thinking),
    ...parseMarkdownBlocks(text),
    if (error != null && error.isNotEmpty) QuoteBlock('⚠️ $error'),
  ];
}

String _providerFor(String modelKey) {
  final int slash = modelKey.indexOf('/');
  return slash <= 0 ? '' : modelKey.substring(0, slash);
}

/// 把统一滑块档位转换成供应商请求所需的预算。
int? _thinkingBudget(ModelSpec model, ThinkingLevel level) {
  final bool supported =
      model.compat.thinking == ThinkingFormat.openaiReasoningEffort ||
      model.compat.thinking == ThinkingFormat.anthropicThinking;
  if (!supported) return null;

  final ThinkingLevel effective = level == ThinkingLevel.off
      ? ThinkingLevel.low
      : level;
  final int budget = switch (effective) {
    ThinkingLevel.low => 4096,
    ThinkingLevel.medium => 10000,
    ThinkingLevel.high => 20000,
    ThinkingLevel.xhigh => 40000,
    ThinkingLevel.max => 80000,
    ThinkingLevel.off => 4096,
  };
  if (model.compat.thinking == ThinkingFormat.anthropicThinking) {
    final int limit = model.maxOutputTokens - 1024;
    return limit < 1024 ? 1024 : (budget > limit ? limit : budget);
  }
  return budget;
}

String _titleFrom(String text) {
  final String flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 16 ? flat : '${flat.substring(0, 16)}…';
}

String _groupLabel(DateTime updatedAt) {
  final DateTime now = DateTime.now();
  final int days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(updatedAt.year, updatedAt.month, updatedAt.day)).inDays;
  if (days <= 0) return '今天';
  if (days == 1) return '昨天';
  if (days < 7) return '过去 7 天';
  if (days < 30) return '过去 30 天';
  return '更早';
}

String _timeLabel(DateTime dt) {
  final String hh = dt.hour.toString().padLeft(2, '0');
  final String mm = dt.minute.toString().padLeft(2, '0');
  return '$hh:$mm';
}
