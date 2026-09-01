# WePChat 会话存储设计


适用平台：Android、Windows

关联文档：`WePChat-Flutter-功能与工具协议.md` §2.1 §2.2、`AGENTS.md` §1.3 §5.3 §6.1 §7 §8

这份文档只负责一件事：**会话数据本身怎么存**。上下文如何拼接、如何命中缓存写在实施 TODO 里，但两者有一条硬接缝——存储必须是追加式且历史不可变，否则 prompt cache 的前缀匹配永远失效。见 §7。

## 1. 需求先于选型

先把真实读写模式列清楚，否则很容易选一个"看起来现代"但读法不匹配的方案。

写入模式：

- 绝大多数写入是**追加**：新消息、新工具结果、新的模型/思考档位变更。
- 历史条目**几乎不修改**。压缩不是修改，是追加一条压缩条目。
- 一轮回复期间产生上百次流式增量，**增量绝不能逐条落盘**。
- 单个工具结果可能很大：`read_file` 截断后仍有数十 KB，`web_fetch` 协议上限 20000 字符。

读取模式（四种，代价差别很大）：

| 场景 | 需要什么 | 频率 |
|---|---|---|
| 组装上下文发给模型 | 最后一个压缩点之后的全部条目，顺序，全文 | 每轮 1 次 |
| 聊天界面渲染 | 从尾部往前分页，全文 | 打开会话 + 滚动 |
| 会话列表 | 标题、时间、预览、token 统计，**不需要正文** | 每次启动 |
| 跨会话搜索 | 明文全文 | 偶发 |

约束：

- 断电或进程被杀不能损坏历史。
- Android 上 IO 慢且不能阻塞 UI isolate（`AGENTS.md` §5.3）。
- 删除会话要能连带清理引用的二进制。

## 2. 为什么不用 JSON

### 2.1 单文件 JSON（每个会话一个 `.json`）

- **写放大是 O(n²)**。追加一条消息要重写整个文件。一个 5 MB 的会话再追加 200 条，累计写入接近 1 GB。手机闪存寿命和电量都不该这么花。
- **冷启动延迟随历史线性增长**。只想看最后一屏，也必须把整个文件反序列化。
- **崩溃即全损**。重写到一半断电，整个会话文件报废，没有可用的部分前缀。
- **会话列表要打开全部文件**才能拿到标题和时间。

### 2.2 JSONL 追加日志（pi 采用的方案）

pi 的 `JsonlSessionStorage` 是首行 header + 每行一条 mutation，加载时全量读入并在内存里重建 `SessionState`，尾行解析失败就把有效前缀原子发布回文件（撕裂尾修复）。

这解决了写放大和崩溃全损，但仍不满足我们的需求：

- **打开会话必须从头扫完整个文件**。CLI 里一个进程一个会话，可以接受；App 里一个 20 MB 的长会话，冷启动要解析 20 MB JSON 才能显示最后一屏。
- **无法按需读取尾部 N 条**，也无法只读元信息。
- **跨会话搜索要遍历所有文件**。
- **没有二级索引**，token 与费用统计每次都要重算。

结论：JSONL 适配"单进程单会话、生命周期短"的 CLI；不适配"几百个会话、需要列表和搜索、冷启动要快"的移动端 App。pi 的**日志语义**（追加、不可变、派生状态回放）值得照搬，**文件格式**不值得。

## 3. 选型

**SQLite（`sqlite3` FFI）承载结构化条目，内容寻址的 blob 目录承载二进制。**

- 追加是单行 insert，无写放大。
- 尾部分页、区间扫描、只读元信息都是索引查询。
- WAL 模式提供崩溃安全，且写不阻塞读。
- 跨会话查询和统计是 SQL 本职工作。
- 单库单文件，备份和迁移简单。

依赖（两个，都同时支持 Android 与 Windows）：

```yaml
sqlite3: ^2.x              # Dart FFI 绑定
sqlite3_flutter_libs: ^0.5.x  # 打包 Android .so 与 Windows sqlite3.dll
```

**不引入 drift。** 理由：我们的查询总量在十几条以内，手写 SQL 更可控；drift 的生成类型会渗透到领域层，违反 `AGENTS.md` §8。代价是迁移和 isolate 封装要自己写，见 §9 §10，量不大。

压缩用 `dart:io` 自带的 `GZipCodec`，不引入压缩依赖。

## 4. 物理布局

```text
App 私有数据目录/
├── wepchat.db          主库
├── wepchat.db-wal      WAL（SQLite 自动管理）
├── wepchat.db-shm
└── blobs/
    └── <sha256 前 2 位>/<sha256>    内容寻址二进制
```

工作区仍按功能协议 §2.1 独立存放在用户设置的根目录下，**不进数据库**。

blobs 与工作区文件的职责区分很重要，否则会出现两份同样的图：

- **工作区文件**是用户产物：可以被用户重命名、删除、在资源管理器里打开。
- **blobs 是进入过上下文的字节**：用户上传的附件、发给模型的图片。入库时按内容哈希复制一份。

之所以要复制：历史会话渲染和重发请求都需要**当初那份字节**。如果上下文只引用工作区路径，用户删掉文件后旧会话就渲染不出图、也无法重发；而且每轮都要重新读盘并 base64 编码。内容寻址还天然去重——同一张图被多轮引用只存一份。

## 5. 表结构

```sql
PRAGMA journal_mode = WAL;      -- 崩溃安全 + 读写并发
PRAGMA synchronous = NORMAL;    -- WAL 下足够，避免每次事务 fsync
PRAGMA foreign_keys = ON;
```

### 5.1 `sessions`

```sql
CREATE TABLE sessions (
  id             TEXT    PRIMARY KEY,   -- ULID，同时是工作区目录名（协议 §2.1）
  title          TEXT    NOT NULL,
  created_at     INTEGER NOT NULL,      -- epoch ms
  updated_at     INTEGER NOT NULL,
  workspace_root TEXT    NOT NULL,      -- 创建时的根；设置改动不迁移旧会话（协议 §2.1）
  provider_id    TEXT    NOT NULL,      -- 派生状态缓存，见 §7.3
  model_id       TEXT    NOT NULL,
  thinking       TEXT    NOT NULL,      -- off | low | medium | high
  preview        TEXT    NOT NULL DEFAULT '',
  head_seq       INTEGER NOT NULL DEFAULT 0,  -- 最后一条条目的 seq
  base_seq       INTEGER NOT NULL DEFAULT 0,  -- 上下文起点，见 §7.2
  context_tokens INTEGER NOT NULL DEFAULT 0,
  cost_total     REAL    NOT NULL DEFAULT 0,
  deleted_at     INTEGER                -- 软删除，便于与工作区目录对账清理
);

CREATE INDEX sessions_recent ON sessions(deleted_at, updated_at DESC);
```

### 5.2 `entries`（追加式事件日志，核心表）

```sql
CREATE TABLE entries (
  session_id  TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  seq         INTEGER NOT NULL,   -- 会话内单调递增，从 1 起
  id          TEXT    NOT NULL,   -- ULID，跨会话唯一
  type        TEXT    NOT NULL,   -- message | compaction | truncate
                                  -- | model_change | thinking_change | tools_change
  role        TEXT,               -- type=message 时：user | assistant | tool_result
  created_at  INTEGER NOT NULL,
  token_est   INTEGER NOT NULL DEFAULT 0,
  stop_reason TEXT,               -- assistant 专用：stop|length|toolUse|aborted|error
  usage_in    INTEGER, usage_out       INTEGER,
  usage_cr    INTEGER, usage_cw        INTEGER,   -- cacheRead / cacheWrite
  cost        REAL,
  encoding    TEXT    NOT NULL,   -- json | gzip | external
  payload     BLOB    NOT NULL,
  PRIMARY KEY (session_id, seq)
) WITHOUT ROWID;

CREATE UNIQUE INDEX entries_id ON entries(id);
```

设计要点：

- `PRIMARY KEY (session_id, seq)` 配 `WITHOUT ROWID`，同一会话的条目在 B-tree 里物理相邻。"读 `seq >= base_seq` 的全部"（组装上下文）和"读尾部 N 条"（界面分页）都变成一次顺序区间扫描，正好是两种主要读法。
- `seq` 不用 `AUTOINCREMENT`（那是全库单调的，会话内会跳号）。单写入者在事务内 `UPDATE sessions SET head_seq = head_seq + 1 RETURNING head_seq` 取号。
- `usage_*` / `stop_reason` / `token_est` 提成列而不是留在 payload 里：压缩阈值判断、费用统计、"丢弃出错的 assistant 轮次"都需要它们，提列后不必反序列化。多数行这些列为 NULL，SQLite 里每个 NULL 只占 1 字节。
- `payload` 是消息本体的 UTF-8 JSON。超过 4 KB 时 gzip，`encoding='gzip'`；超过 256 KB 时不进库，写入 blob 目录，`encoding='external'` 且 payload 存 sha256 十六进制。理由：可调试性优先于极限性能，压缩收益集中在少数大工具结果上；巨大单行会拉长 SQLite 的溢出页链。

### 5.3 `blobs` 与引用

```sql
CREATE TABLE blobs (
  sha256     TEXT    PRIMARY KEY,
  bytes      INTEGER NOT NULL,
  mime       TEXT    NOT NULL,
  created_at INTEGER NOT NULL
);

CREATE TABLE blob_refs (
  sha256     TEXT    NOT NULL REFERENCES blobs(sha256),
  session_id TEXT    NOT NULL,
  seq        INTEGER NOT NULL,
  PRIMARY KEY (sha256, session_id, seq)
) WITHOUT ROWID;

CREATE INDEX blob_refs_session ON blob_refs(session_id);
```

删除会话时删掉 refs；`blobs` 里引用计数归零的条目在空闲时机 GC（一次 `LEFT JOIN` 扫描 + 删文件）。GC 必须是"先删表行、再删文件"，反过来会留下有记录无文件的悬挂引用。

### 5.4 `runs`（中断标记，非完整恢复）

```sql
CREATE TABLE runs (
  id          TEXT    PRIMARY KEY,
  session_id  TEXT    NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
  started_at  INTEGER NOT NULL,
  finished_at INTEGER,     -- NULL 且进程重启 ⇒ 上次被中断
  outcome     TEXT         -- completed | aborted | error
);
```

见 §6.2。不实现 pi 那套完整的可恢复运行协议（`step_attempt` / `tool_started` 记录 + reducer 回放），理由见该节。

## 6. 写入路径

### 6.1 流式期间不落盘

- 流式增量只存在内存里的 partial 消息中，界面直接消费 agent 事件。
- **助手消息在 `message_end` 时整条落盘**，一个事务里 insert entry + 更新 `sessions` 的 `head_seq`/`updated_at`/`preview`/`context_tokens`/`cost_total`。
- **工具结果每个执行完立刻单独落盘**，不等整轮结束。

第二条和第三条的差别是刻意的：工具已经产生了真实副作用（文件被写、图片被生成）。如果整轮一起落盘，中途崩溃后重启，磁盘上文件变了而上下文里没有对应的工具结果，模型会做出基于错误前提的决策。助手文本没有副作用，丢了重新生成即可。

### 6.2 崩溃恢复的边界

进程被杀时，正在流式生成的那条助手消息会丢失。我们**不自动续跑**：

- 启动时扫 `runs` 里 `finished_at IS NULL` 的行，标为中断，界面显示"上次回复被中断，可重试"。
- 已落盘的工具结果保留——它们对应真实发生过的副作用。

pi 用 `OperationStartedRecord` / `StepAttemptRecord` / `ToolStartedRecord` 加一个 667 行的 reducer 做精确恢复（而且 `agent-harness.ts` 里这套还基本是未实现的桩）。那个复杂度服务于"无人值守的长任务必须自愈"。WePChat 是交互式聊天客户端，用户就在屏幕前，"告诉他中断了并给个重试按钮"是更合适的产品行为，也省掉一整层状态机。

## 7. 追加式存储与 prompt cache 前缀稳定

这是存储层与 API 层的接缝，值得单独一节。

### 7.1 不可变前缀 ⇒ 缓存命中

Anthropic 的 `cache_control` 和 OpenAI 的 `prompt_cache_key` 都基于**请求前缀逐字节匹配**。只要 `entries` 里的条目一旦写入就不再变动，同一段历史每次序列化出的字节就完全一致，前缀天然稳定。

因此以下操作被明确禁止：

- 回填、修正、重新格式化已有条目。
- 为了"整理"而合并或重排历史条目。
- 在 payload 里写入随请求变化的值（当前时间、随机 ID）。

### 7.2 压缩是追加，不是重写

压缩追加一条 `type='compaction'` 的条目，payload 含摘要与保留的尾部消息；同时把 `sessions.base_seq` 指向这条条目的 `seq`。上下文组装从 `base_seq` 起读：

```sql
SELECT seq, type, role, encoding, payload
FROM entries
WHERE session_id = ?1 AND seq >= ?2   -- ?2 = sessions.base_seq
ORDER BY seq;
```

旧条目**不删**：界面还要展示完整历史，将来"撤销压缩"也需要它们。

压缩发生的那一轮必然缓存未命中，之后重新稳定。所以压缩阈值要留足余量，不能贴着上下文窗口反复触发。

### 7.3 派生状态靠回放，不靠就地修改

当前模型、思考档位、启用的工具集由 `model_change` / `thinking_change` / `tools_change` 条目回放得到。`sessions` 表上的同名列只是展示用缓存；两者不一致时**以回放为准**，并把这种不一致当作 bug 报错，不静默采用缓存值（`AGENTS.md` §1.3）。

## 8. 编辑重发

聊天客户端要能"改掉上一句重发"。在追加式模型里不做成树，而是追加一条 `type='truncate'` 条目，payload 记录被截断的起点 `seq`。组装上下文时先收集全部 truncate 标记，跳过被覆盖的区间。

好处是仍然只追加，历史完整可见，实现量很小。代价是不支持多分支并行对话——功能协议里没有这个需求，需要时再迁移成 `parent_seq` 树，届时是一次加列迁移。现在不预留列（`AGENTS.md` §3）。

## 9. 迁移

- 版本号存 `PRAGMA user_version`。
- 一个有序的 `List<Migration>`，每步一个事务，只允许向前。
- 打开时若 `user_version` 大于当前代码支持的版本（用户装过更新的版本又降级），**明确报错并拒绝打开**，不尝试兼容读取。
- FTS 表（§11）在后续版本以增量迁移加入，第一版不建。

## 10. 并发与 isolate

- 一个长驻 DB isolate 持有**唯一写连接**，所有读写经 `SendPort` 串行。这同时满足 `AGENTS.md` §5.3（不在 UI isolate 做阻塞 IO）与 §6.2（同一工作区的写必须串行）在存储层的对应要求。
- WAL 允许再开只读连接做并发读，但第一版不做——先用单连接把正确性做对，性能不足再加。
- `sqlite3_flutter_libs` 在 isolate 中加载 native 库的行为需要实机验证，尤其 Android 各 ABI。

## 11. 全文搜索（后续版本）

中文是关键难点：FTS5 默认的 `unicode61` 分词按空白和标点切，一整段中文会变成一个 token，搜不出来。可选 `trigram` 分词器，支持子串匹配，对中日韩友好，代价是索引体积约为 3～4 倍。

```sql
CREATE VIRTUAL TABLE entries_fts USING fts5(
  text, session_id UNINDEXED, seq UNINDEXED, tokenize = 'trigram'
);
```

只索引可读文本：用户消息、助手文本、压缩摘要。不索引思考内容和大工具结果——体积换不来检索价值。

`sqlite3_flutter_libs` 编译的 SQLite 是否启用了 FTS5 与 trigram，需实测确认。

## 12. 记忆存储（需用户确认的偏离）

功能协议 §2.2 规定全局记忆存 App 私有目录下的 `memory.json`。

既然会话已经落在同一个库里，建议记忆也用一张表，而不是单独维护一个 JSON 文件：

```sql
CREATE TABLE memories (
  id         TEXT    PRIMARY KEY,   -- 例如 pref_ui_style
  category   TEXT    NOT NULL,
  key        TEXT    NOT NULL,
  value      TEXT    NOT NULL,
  updated_at INTEGER NOT NULL,
  UNIQUE (category, key)            -- 相同 category+key 更新而非新增（协议 §7.2）
);
```

好处：`UNIQUE(category, key)` 由数据库保证协议 §7.2 的更新语义，不用在代码里手写查重；`list_memory` 只取摘要不必读全文；不必再写一套 JSON 文件的原子写入与损坏恢复。

访问边界不变：只有 `save_memory` / `list_memory` / `read_memory` 能碰这张表，普通文件工具和 `run_js` 都碰不到（`AGENTS.md` §6.3）。因为 `run_js` 根本不接触真实路径，它连库文件在哪都不知道——这一点上表比文件更安全。

**这是对功能协议 §2.2 的偏离，需要确认后才改协议文档。**

## 13. 容量与性能预估

粗算，用于确认量级而非精确容量：

| 场景 | 条目数 | 库体积 | 组装上下文读取 |
|---|---|---|---|
| 日常会话 | ~60 | < 200 KB | 一次区间扫描，几 ms |
| 长会话（含大量工具结果） | ~800 | 10～40 MB | 只读 `base_seq` 之后，与总量无关 |
| 300 个会话的库 | — | 几百 MB | 列表查询走索引，不读 payload |

关键性质：**组装上下文的成本只与压缩点之后的条目数相关，与会话总长无关**。这是单文件 JSON 和 JSONL 都做不到的。

## 14. 待定决策

1. **`sqlite3` 手写 DAO** 还是 drift。本文档选前者，理由见 §3。
2. **记忆迁到表**（§12）是否接受，需要同步修改功能协议 §2.2。
3. **不做自动恢复**（§6.2）只做中断提示，是否接受。
4. **编辑重发用 truncate 标记**而非分支树（§8），是否接受。
5. blob GC 的触发时机：启动时、空闲时、还是仅在删除会话时。倾向"删除会话时立即 + 启动时兜底扫描"。
