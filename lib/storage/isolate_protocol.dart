/// DB isolate 的请求/响应类型（存储设计 §10）。
///
/// 这些对象经 `SendPort` 传递。同一 isolate group 内可以直接发送用户类实例，
/// 所以不做 Map 序列化——手写 toJson/fromJson 是两处可以各自漂移的实现
/// （AGENTS.md §1.2），而且每加一个字段要改两个地方。
///
/// 约束：字段只能是可发送类型（基本类型、String、List、Map、以及同样只含
/// 可发送字段的对象）。不能放 Database、ReceivePort、闭包。
library;

import 'entry_record.dart';
import 'memory_record.dart';
import 'models.dart';
import 'session_record.dart';

/// 请求基类。[id] 用于把响应配回等待中的 Completer。
sealed class DbRequest {
  const DbRequest(this.id);

  final int id;
}

class ListSessionSummariesRequest extends DbRequest {
  const ListSessionSummariesRequest(super.id, {this.limit = 200});

  final int limit;
}

class FindSessionRequest extends DbRequest {
  const FindSessionRequest(super.id, this.sessionId);

  final String sessionId;
}

class CreateSessionRequest extends DbRequest {
  const CreateSessionRequest(super.id, this.session);

  final SessionRecord session;
}

class RenameSessionRequest extends DbRequest {
  const RenameSessionRequest(super.id, this.sessionId, this.title);

  final String sessionId;
  final String title;
}

/// 追加条目。[preview] / [contextTokens] / [costDelta] 非空时一并更新
/// `sessions` 的汇总列，与插入同事务（存储设计 §6.1）。
class AppendEntryRequest extends DbRequest {
  const AppendEntryRequest(
    super.id,
    this.sessionId,
    this.entry, {
    this.preview,
    this.contextTokens,
    this.costDelta,
  });

  final String sessionId;
  final NewEntry entry;
  final String? preview;
  final int? contextTokens;
  final double? costDelta;
}

/// 组装上下文：读 `seq >= base_seq` 的全部条目（存储设计 §7.2）。
class ReadContextRequest extends DbRequest {
  const ReadContextRequest(super.id, this.sessionId);

  final String sessionId;
}

/// 界面分页：读尾部 N 条。
class ReadTailRequest extends DbRequest {
  const ReadTailRequest(
    super.id,
    this.sessionId, {
    this.limit = 50,
    this.beforeSeq,
  });

  final String sessionId;
  final int limit;
  final int? beforeSeq;
}

/// 回放派生状态（模型 / 思考档位 / 工具集）。
class ReadDerivedStateRequest extends DbRequest {
  const ReadDerivedStateRequest(super.id, this.sessionId);

  final String sessionId;
}

/// 改模型：追加 `model_change` 条目 + 更新缓存列，同事务。
class ChangeModelRequest extends DbRequest {
  const ChangeModelRequest(
    super.id,
    this.sessionId, {
    required this.entryId,
    required this.providerId,
    required this.modelId,
  });

  final String sessionId;
  final String entryId;
  final String providerId;
  final String modelId;
}

/// 改思考档位：追加 `thinking_change` 条目 + 更新缓存列，同事务。
class ChangeThinkingRequest extends DbRequest {
  const ChangeThinkingRequest(
    super.id,
    this.sessionId, {
    required this.entryId,
    required this.thinking,
  });

  final String sessionId;
  final String entryId;
  final ThinkingLevel thinking;
}

/// 压缩会话：追加 `compaction` 条目 + 把 `base_seq` 推到那条，同事务
/// （存储设计 §7.2）。
///
/// 原始条目一条都不删。追加式日志是 prompt cache 前缀稳定的前提，
/// 删掉旧条目虽然省空间，但也就永久失去了"回看压缩前说过什么"的能力。
/// 压缩只是移动上下文起点。
class CompressSessionRequest extends DbRequest {
  const CompressSessionRequest(
    super.id,
    this.sessionId, {
    required this.entryId,
    required this.summary,
    required this.replacedThrough,
    this.tokenEst = 0,
  });

  final String sessionId;
  final String entryId;

  /// 摘要正文，替代 `replacedThrough` 及之前的条目进上下文。
  final String summary;

  /// 被这条摘要覆盖到的最后一个 seq。
  final int replacedThrough;

  /// 摘要自身的 token 估算，供上下文预算统计。
  final int tokenEst;
}

/// 删除会话（存储设计 §9-11）。工作区目录的清理不在存储层做
/// ——那是用户产物，要先确认用户意图。
class DeleteSessionRequest extends DbRequest {
  const DeleteSessionRequest(super.id, this.sessionId);

  final String sessionId;
}

/// 启动时扫未结束的 run，标为中断（存储设计 §6.2）。
class ReconcileInterruptedRunsRequest extends DbRequest {
  const ReconcileInterruptedRunsRequest(super.id);
}

class StartRunRequest extends DbRequest {
  const StartRunRequest(super.id, this.runId, this.sessionId);

  final String runId;
  final String sessionId;
}

class FinishRunRequest extends DbRequest {
  const FinishRunRequest(super.id, this.runId, this.outcome);

  final String runId;
  final RunOutcome outcome;
}

class CollectBlobGarbageRequest extends DbRequest {
  const CollectBlobGarbageRequest(super.id);
}

// ---- 记忆 ----

class ListMemoriesRequest extends DbRequest {
  const ListMemoriesRequest(super.id, {this.category});

  final String? category;
}

class ReadMemoryRequest extends DbRequest {
  const ReadMemoryRequest(super.id, this.memoryId);

  final String memoryId;
}

class SaveMemoryRequest extends DbRequest {
  const SaveMemoryRequest(super.id, this.memory);

  final MemoryRecord memory;
}

class DeleteMemoryRequest extends DbRequest {
  const DeleteMemoryRequest(super.id, this.memoryId);

  final String memoryId;
}

/// 让 isolate 关掉连接并退出。
class ShutdownRequest extends DbRequest {
  const ShutdownRequest(super.id);
}

/// 响应基类。
sealed class DbResponse {
  const DbResponse(this.id);

  final int id;
}

class DbSuccess extends DbResponse {
  const DbSuccess(super.id, this.value);

  final Object? value;
}

/// 失败响应。[error] 是原始领域错误（[WepError] 子类，可发送）；
/// [stackTrace] 转成字符串，因为 StackTrace 本身不保证可发送。
class DbFailure extends DbResponse {
  const DbFailure(super.id, this.error, this.stackTrace);

  final Object error;
  final String stackTrace;
}
