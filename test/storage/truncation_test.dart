import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/storage/entry_record.dart';
import 'package:wepchat/storage/models.dart';
import 'package:wepchat/storage/truncation.dart';

void main() {
  group('applyTruncations', () {
    test('无标记时原样返回', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _entry(seq: 2, type: EntryType.message),
      ];
      expect(applyTruncations(entries), equals(entries));
    });

    test('撤回之后的全部条目', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _entry(seq: 2, type: EntryType.message),
        _entry(seq: 3, type: EntryType.message),
        _truncate(seq: 4, fromSeq: 2),
      ];
      final List<EntryRecord> live = applyTruncations(entries);
      expect(live.map((EntryRecord e) => e.seq), <int>[1]);
    });

    test('标记之后新追加的条目保留', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _entry(seq: 2, type: EntryType.message),
        _truncate(seq: 3, fromSeq: 2),
        _entry(seq: 4, type: EntryType.message),
        _entry(seq: 5, type: EntryType.message),
      ];
      final List<EntryRecord> live = applyTruncations(entries);
      expect(live.map((EntryRecord e) => e.seq), <int>[1, 4, 5]);
    });

    test('多条标记各自生效', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _entry(seq: 2, type: EntryType.message),
        _entry(seq: 3, type: EntryType.message),
        _truncate(seq: 4, fromSeq: 2),
        _entry(seq: 5, type: EntryType.message),
        _truncate(seq: 6, fromSeq: 5),
      ];
      final List<EntryRecord> live = applyTruncations(entries);
      expect(live.map((EntryRecord e) => e.seq), <int>[1]);
    });

    test('无效的 fromSeq（类型错）不撤回任何条目', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _entry(seq: 2, type: EntryType.message),
        _truncate(seq: 3, payload: <String, Object?>{'fromSeq': 'bad'}),
      ];
      final List<EntryRecord> live = applyTruncations(entries);
      expect(live.map((EntryRecord e) => e.seq), <int>[1, 2]);
    });

    test('payload 里没有 fromSeq 时当作无效', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _truncate(seq: 2, payload: <String, Object?>{}),
      ];
      final List<EntryRecord> live = applyTruncations(entries);
      expect(live.map((EntryRecord e) => e.seq), <int>[1]);
    });

    test('标记本身不出现在结果里', () {
      final List<EntryRecord> entries = <EntryRecord>[
        _entry(seq: 1, type: EntryType.message),
        _truncate(seq: 2, fromSeq: 999),
      ];
      final List<EntryRecord> live = applyTruncations(entries);
      expect(live, hasLength(1));
      expect(live.first.type, EntryType.message);
    });
  });
}

EntryRecord _entry({
  required int seq,
  required EntryType type,
  Map<String, Object?>? payload,
}) {
  return EntryRecord(
    sessionId: 'test-session',
    seq: seq,
    id: 'id$seq',
    type: type,
    role: EntryRole.user,
    createdAt: DateTime.now(),
    payload: payload ?? <String, Object?>{},
    tokenEst: 0,
    stopReason: null,
    usage: const TokenUsage(),
  );
}

EntryRecord _truncate({
  required int seq,
  int? fromSeq,
  Map<String, Object?>? payload,
}) {
  return _entry(
    seq: seq,
    type: EntryType.truncate,
    payload: payload ??
        (fromSeq == null
            ? <String, Object?>{}
            : <String, Object?>{kTruncateFromSeq: fromSeq}),
  );
}
