/// 适配器 → 存储的停止原因与用量映射（实施 TODO M1）。
///
/// `lib/ai/messages.dart` 和 `lib/storage/models.dart` 各有一套同名的
/// `StopReason` / `TokenUsage`：前者是请求/响应领域模型，后者是持久化模型，
/// 字段和语义都不同。隔离映射逻辑到这个文件，session_store 才能同时 import
/// 两边而不产生命名冲突。
library;

import '../ai/messages.dart' as ai;
import '../storage/models.dart' as storage;

/// AI 层的 StopReason → 存储层的 StopReason。
storage.StopReason toStorageStopReason(ai.StopReason reason) {
  return switch (reason) {
    ai.StopReason.stop => storage.StopReason.stop,
    ai.StopReason.toolUse => storage.StopReason.toolUse,
    ai.StopReason.length => storage.StopReason.length,
    ai.StopReason.error => storage.StopReason.error,
    ai.StopReason.aborted => storage.StopReason.aborted,
  };
}

/// AI 层的 TokenUsage → 存储层的 TokenUsage。
///
/// 存储层字段全是 nullable，直接映射过去；cost 目前不算，传 null。
storage.TokenUsage toStorageTokenUsage(ai.TokenUsage usage) {
  if (usage.isEmpty) return const storage.TokenUsage();
  return storage.TokenUsage(
    inputTokens: usage.inputTokens,
    outputTokens: usage.outputTokens,
    cacheReadTokens: usage.cacheReadTokens,
    cacheWriteTokens: usage.cacheWriteTokens,
    cost: null, // M3 再算。
  );
}
