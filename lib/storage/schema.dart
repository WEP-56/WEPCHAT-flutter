/// 数据库表结构（存储设计 §5）。
///
/// 建表语句集中在这一个文件，所有 DAO 和迁移引用这里的常量。
/// 不在各处写 `CREATE TABLE`（AGENTS.md §1.2）。
library;

/// 数据库模式版本，存在 `PRAGMA user_version` 里。
const int kSchemaVersion = 1;

/// 每次打开连接都要执行的 PRAGMA。
///
/// 三条的作用域不同，这是它们不能放进迁移的原因：
/// - `journal_mode` 持久化在库文件里，但**不允许在事务内修改**，
///   放进迁移事务会报 "cannot change into wal mode from within a transaction"。
/// - `synchronous` 与 `foreign_keys` 是**连接级**的，每条连接都要重设，
///   只在建库那一次执行等于后续连接全部失效。
const List<String> kConnectionPragmas = <String>[
  'PRAGMA journal_mode = WAL', // 崩溃安全 + 读写并发
  'PRAGMA synchronous = NORMAL', // WAL 下足够，避免每次事务 fsync
  'PRAGMA foreign_keys = ON', // ON DELETE CASCADE 生效的前提
];

/// v1 的建表语句。只含 DDL，可安全放进一个事务。
const List<String> kSchemaV1 = <String>[
  kCreateSessions,
  kCreateSessionsIndex,
  kCreateEntries,
  kCreateEntriesIdIndex,
  kCreateBlobs,
  kCreateBlobRefs,
  kCreateBlobRefsSessionIndex,
  kCreateRuns,
];

/// `sessions` 表：会话元信息 + 派生状态缓存（存储设计 §5.1）。
///
/// `provider_id` / `model_id` / `thinking` 是**缓存列**，权威值靠
/// `*_change` 条目回放得到（存储设计 §7.3）。
const String kCreateSessions = '''
CREATE TABLE sessions (
  id             TEXT    PRIMARY KEY,
  title          TEXT    NOT NULL,
  created_at     INTEGER NOT NULL,
  updated_at     INTEGER NOT NULL,
  workspace_root TEXT    NOT NULL,
  provider_id    TEXT    NOT NULL,
  model_id       TEXT    NOT NULL,
  thinking       TEXT    NOT NULL,
  preview        TEXT    NOT NULL DEFAULT '',
  head_seq       INTEGER NOT NULL DEFAULT 0,
  base_seq       INTEGER NOT NULL DEFAULT 0,
  context_tokens INTEGER NOT NULL DEFAULT 0,
  cost_total     REAL    NOT NULL DEFAULT 0,
  deleted_at     INTEGER
)''';

const String kCreateSessionsIndex =
    'CREATE INDEX sessions_recent ON sessions(deleted_at, updated_at DESC)';

/// `entries` 表：追加式事件日志，核心表（存储设计 §5.2）。
///
/// `PRIMARY KEY (session_id, seq)` 配 `WITHOUT ROWID` 让同一会话的条目在
/// B-tree 里物理相邻，"读 seq >= base_seq"（组装上下文）与"读尾部 N 条"
/// （界面分页）都变成一次顺序区间扫描。
const String kCreateEntries = '''
CREATE TABLE entries (
  session_id  TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL,
  id          TEXT    NOT NULL,
  type        TEXT    NOT NULL,
  role        TEXT,
  created_at  INTEGER NOT NULL,
  token_est   INTEGER NOT NULL DEFAULT 0,
  stop_reason TEXT,
  usage_in    INTEGER,
  usage_out   INTEGER,
  usage_cr    INTEGER,
  usage_cw    INTEGER,
  cost        REAL,
  encoding    TEXT    NOT NULL,
  payload     BLOB    NOT NULL,
  PRIMARY KEY (session_id, seq)
) WITHOUT ROWID''';

const String kCreateEntriesIdIndex =
    'CREATE UNIQUE INDEX entries_id ON entries(id)';

/// `blobs` 表：内容寻址的二进制（存储设计 §5.3）。
const String kCreateBlobs = '''
CREATE TABLE blobs (
  sha256     TEXT    PRIMARY KEY,
  bytes      INTEGER NOT NULL,
  mime       TEXT    NOT NULL,
  created_at INTEGER NOT NULL
)''';

/// `blob_refs` 表：blob 引用关系，引用计数归零后 GC。
const String kCreateBlobRefs = '''
CREATE TABLE blob_refs (
  sha256     TEXT    NOT NULL REFERENCES blobs(sha256),
  session_id TEXT    NOT NULL,
  seq        INTEGER NOT NULL,
  PRIMARY KEY (sha256, session_id, seq)
) WITHOUT ROWID''';

const String kCreateBlobRefsSessionIndex =
    'CREATE INDEX blob_refs_session ON blob_refs(session_id)';

/// `runs` 表：中断标记，非完整恢复（存储设计 §5.4 §6.2）。
const String kCreateRuns = '''
CREATE TABLE runs (
  id          TEXT    PRIMARY KEY,
  session_id  TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  started_at  INTEGER NOT NULL,
  finished_at INTEGER,
  outcome     TEXT
)''';
