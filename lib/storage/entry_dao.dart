import 'dart:typed_data';

import 'package:sqlite3/sqlite3.dart';

import '../core/errors.dart';
import 'blob_store.dart';
import 'entry_record.dart';
import 'models.dart';
import 'payload_codec.dart';

/// 追加一条条目后的结果。
class AppendedEntry {
  const AppendedEntry({required this.seq, required this.plainBytes});

  /// 事务内取到的号。
  final int seq;

  /// 未压缩的 payload 字节数，供统计。
  final int plainBytes;
}

/// `entries` 表的读写（存储设计 §5.2 §6 §7.2）。
///
/// 只在 DB isolate 内使用。
class EntryDao {
  EntryDao(this._db, this._blobs, {PayloadCodec codec = const PayloadCodec()})
    : _codec = codec;

  final Database _db;
  final BlobStore _blobs;
  final PayloadCodec _codec;

  /// 追加一条条目，同事务内取号并更新 `sessions` 的汇总列。
  ///
  /// 取号用 `UPDATE ... RETURNING`，把"读当前值"和"加一"合成一条原子语句
  /// ——分两步做会在并发下撞号。当前只有一个写连接（存储设计 §10），
  /// 但这条保证让将来加只读连接时不必回头改。
  ///
  /// 调用方负责已经开好事务。这个方法自己不 BEGIN，因为助手消息落盘要和
  /// 更新会话汇总在同一个事务里（存储设计 §6.1）。
  AppendedEntry append(
    String sessionId,
    NewEntry entry, {
    required DateTime now,
    String? preview,
    int? contextTokens,
    double? costDelta,
  }) {
    final int seq = _nextSeq(sessionId);
    final EncodedPayload encoded = _codec.encode(entry.payload);

    final Uint8List stored;
    if (encoded.encoding == PayloadEncoding.external) {
      // 大 payload 落 blob，payload 列只存 sha256（存储设计 §5.2）。
      final String sha = _blobs.put(
        encoded.bytes,
        mime: 'application/json',
        sessionId: sessionId,
        seq: seq,
      );
      stored = _codec.encodeExternalRef(sha);
    } else {
      stored = encoded.bytes;
    }

    final DateTime createdAt = entry.createdAt ?? now;
    _db.execute(
      '''
INSERT INTO entries (
  session_id, seq, id, type, role, created_at, token_est, stop_reason,
  usage_in, usage_out, usage_cr, usage_cw, cost, encoding, payload
) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)''',
      <Object?>[
        sessionId,
        seq,
        entry.id,
        entry.type.wire,
        entry.role?.wire,
        createdAt.millisecondsSinceEpoch,
        entry.tokenEst,
        entry.stopReason?.wire,
        entry.usage.inputTokens,
        entry.usage.outputTokens,
        entry.usage.cacheReadTokens,
        entry.usage.cacheWriteTokens,
        entry.usage.cost,
        encoded.encoding.wire,
        stored,
      ],
    );

    _updateSessionAggregates(
      sessionId,
      now: now,
      preview: preview,
      contextTokens: contextTokens,
      costDelta: costDelta,
    );

    return AppendedEntry(seq: seq, plainBytes: encoded.plainBytes);
  }

  /// 组装上下文用的读法：`seq >= base_seq` 顺序全取（存储设计 §7.2）。
  ///
  /// 成本只与压缩点之后的条目数相关，与会话总长无关。
  List<EntryRecord> readFromBaseSeq(String sessionId) {
    final ResultSet rows = _db.select(
      '''
SELECT e.* FROM entries e
JOIN sessions s ON s.id = e.session_id
WHERE e.session_id = ? AND e.seq >= s.base_seq
ORDER BY e.seq''',
      <Object?>[sessionId],
    );
    return _decodeRows(rows);
  }

  /// 界面分页用的读法：尾部 N 条。
  ///
  /// [beforeSeq] 为空取最新一页；翻页时传上一页最小的 seq。
  /// 返回**按 seq 升序**——倒序取到后翻转，界面不用自己排。
  List<EntryRecord> readTail(
    String sessionId, {
    int limit = 50,
    int? beforeSeq,
  }) {
    final ResultSet rows = beforeSeq == null
        ? _db.select(
            'SELECT * FROM entries WHERE session_id = ? '
            'ORDER BY seq DESC LIMIT ?',
            <Object?>[sessionId, limit],
          )
        : _db.select(
            'SELECT * FROM entries WHERE session_id = ? AND seq < ? '
            'ORDER BY seq DESC LIMIT ?',
            <Object?>[sessionId, beforeSeq, limit],
          );

    return _decodeRows(rows).reversed.toList(growable: false);
  }

  /// 回放派生状态用：只取 `*_change` 条目（存储设计 §7.3）。
  List<EntryRecord> readStateChanges(String sessionId) {
    final ResultSet rows = _db.select(
      '''
SELECT * FROM entries
WHERE session_id = ? AND type IN (?, ?, ?)
ORDER BY seq''',
      <Object?>[
        sessionId,
        EntryType.modelChange.wire,
        EntryType.thinkingChange.wire,
        EntryType.toolsChange.wire,
      ],
    );
    return _decodeRows(rows);
  }

  /// 事务内取号。`RETURNING` 让读改写成为一条原子语句。
  int _nextSeq(String sessionId) {
    final ResultSet rows = _db.select(
      'UPDATE sessions SET head_seq = head_seq + 1 WHERE id = ? '
      'RETURNING head_seq',
      <Object?>[sessionId],
    );
    if (rows.isEmpty) {
      throw StorageError(
        '会话不存在，无法追加条目',
        context: <String, Object?>{'sessionId': sessionId},
      );
    }
    return rows.first['head_seq'] as int;
  }

  /// 更新会话的汇总列。与条目插入在同一事务里（存储设计 §6.1）。
  ///
  /// `cost_total` 用增量累加而不是整体重算——重算要扫全部条目，
  /// 每次追加都做一遍是 O(n²)。
  void _updateSessionAggregates(
    String sessionId, {
    required DateTime now,
    String? preview,
    int? contextTokens,
    double? costDelta,
  }) {
    final List<String> sets = <String>['updated_at = ?'];
    final List<Object?> args = <Object?>[now.millisecondsSinceEpoch];

    if (preview != null) {
      sets.add('preview = ?');
      args.add(preview);
    }
    if (contextTokens != null) {
      sets.add('context_tokens = ?');
      args.add(contextTokens);
    }
    if (costDelta != null && costDelta != 0) {
      sets.add('cost_total = cost_total + ?');
      args.add(costDelta);
    }

    args.add(sessionId);
    _db.execute('UPDATE sessions SET ${sets.join(', ')} WHERE id = ?', args);
  }

  List<EntryRecord> _decodeRows(ResultSet rows) =>
      rows.map(_toRecord).toList(growable: false);

  EntryRecord _toRecord(Row r) {
    final PayloadEncoding encoding = PayloadEncoding.fromWire(
      r['encoding'] as String,
    );
    final Uint8List stored = _asBytes(r['payload']);

    final Map<String, Object?> payload;
    if (encoding == PayloadEncoding.external) {
      final String sha = _codec.decodeExternalRef(stored);
      payload = _codec.decodeBytes(_blobs.read(sha));
    } else {
      payload = _codec.decode(encoding, stored);
    }

    final String? role = r['role'] as String?;
    final String? stopReason = r['stop_reason'] as String?;

    return EntryRecord(
      sessionId: r['session_id'] as String,
      seq: r['seq'] as int,
      id: r['id'] as String,
      type: EntryType.fromWire(r['type'] as String),
      role: role == null ? null : EntryRole.fromWire(role),
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['created_at'] as int),
      tokenEst: r['token_est'] as int,
      stopReason: stopReason == null ? null : StopReason.fromWire(stopReason),
      usage: TokenUsage(
        inputTokens: r['usage_in'] as int?,
        outputTokens: r['usage_out'] as int?,
        cacheReadTokens: r['usage_cr'] as int?,
        cacheWriteTokens: r['usage_cw'] as int?,
        cost: (r['cost'] as num?)?.toDouble(),
      ),
      payload: payload,
    );
  }

  /// SQLite 的 BLOB 列在 sqlite3 包里出来是 `Uint8List`，但 `TEXT` 写入的
  /// 值可能是 `String`。payload 列声明为 BLOB，两种都兜住比在写入侧
  /// 假设类型更安全。
  static Uint8List _asBytes(Object? value) {
    if (value is Uint8List) return value;
    if (value is List<int>) return Uint8List.fromList(value);
    throw StorageError(
      'payload 列类型异常',
      context: <String, Object?>{'actualType': value.runtimeType},
    );
  }
}
