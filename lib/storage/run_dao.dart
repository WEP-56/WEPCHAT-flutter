import 'package:sqlite3/sqlite3.dart';

import 'models.dart';

/// `runs` 表：中断标记（存储设计 §5.4 §6.2）。
///
/// 这不是 pi 那套可恢复运行协议。我们只记"开始了"和"结束了"，
/// 进程被杀后靠 `finished_at IS NULL` 判断上次被中断，界面提示可重试。
/// 用户就在屏幕前，告诉他中断了比自愈状态机更合适，也省掉一整层状态机。
class RunDao {
  RunDao(this._db);

  final Database _db;

  void start(String runId, String sessionId, DateTime now) {
    _db.execute(
      'INSERT INTO runs (id, session_id, started_at) VALUES (?, ?, ?)',
      <Object?>[runId, sessionId, now.millisecondsSinceEpoch],
    );
  }

  void finish(String runId, RunOutcome outcome, DateTime now) {
    _db.execute(
      'UPDATE runs SET finished_at = ?, outcome = ? WHERE id = ?',
      <Object?>[now.millisecondsSinceEpoch, outcome.wire, runId],
    );
  }

  /// 启动时调用：把所有未结束的 run 标为中断，返回受影响的会话 id。
  ///
  /// 进程还活着时不会有"未结束但已死"的 run，所以这个操作只在启动路径上
  /// 有意义；重复调用是幂等的（第二次没有 `finished_at IS NULL` 的行）。
  List<String> reconcileInterrupted(DateTime now) {
    final ResultSet rows = _db.select(
      'SELECT DISTINCT session_id FROM runs WHERE finished_at IS NULL',
    );
    final List<String> sessionIds = rows
        .map((Row r) => r['session_id'] as String)
        .toList(growable: false);

    if (sessionIds.isNotEmpty) {
      _db.execute(
        'UPDATE runs SET finished_at = ?, outcome = ? '
        'WHERE finished_at IS NULL',
        <Object?>[now.millisecondsSinceEpoch, RunOutcome.aborted.wire],
      );
    }

    return sessionIds;
  }
}
