/// 存储层公开接口（存储设计 §1–§10）。
///
/// 上层只 import 这一个文件，看不到 sqlite3、isolate 协议和 DAO 细节。
library;

export 'blob_store.dart' show BlobGcResult;
export 'entry_record.dart' show EntryRecord, NewEntry;
export 'models.dart'
    show
        EntryRole,
        EntryType,
        RunOutcome,
        StopReason,
        ThinkingLevel,
        TokenUsage;
export 'session_record.dart' show SessionRecord, SessionSummary;
export 'wep_storage.dart' show WepStorage;
