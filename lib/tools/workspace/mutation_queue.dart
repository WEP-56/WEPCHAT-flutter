/// 工作区写入的串行化队列（实施 TODO §7-14，AGENTS.md §6.2）。
///
/// 读类工具可以并行，同一个工作区的**写入、编辑、删除必须串行**。
///
/// 为什么需要它，尽管 `AgentLoop` 已经是逐个执行工具的：串行只是当前
/// 循环实现的一个副产品，不是它承诺的性质。协议 §10.1 明写要支持"工具
/// 并行执行"，那一天到来时，`edit_file` 的读—改—写会和另一个 `write_file`
/// 交错，后写的那个把前一个的修改整个盖掉，而两个工具都会报成功。
/// 把串行钉在写入这一侧，改循环时就不必记得这条约束。
library;

import 'dart:async';

/// 按工作区根目录串行化写操作。
///
/// 全局单例：队列必须覆盖同一个目录的所有写入方，各建各的等于没有队列。
/// 不同工作区之间互不阻塞——它们本来就不会互相覆盖。
class MutationQueue {
  MutationQueue._();

  static final MutationQueue instance = MutationQueue._();

  final Map<String, Future<void>> _tails = <String, Future<void>>{};

  /// 把 [action] 排到 [workspaceRoot] 这条队列的末尾，等前面的都做完再跑。
  ///
  /// [action] 抛出的异常照常传给调用方，但**不会**打断队列：后面排着的
  /// 操作照跑。一个工具写失败不该让接下来的所有写入一起卡住。
  Future<T> run<T>(String workspaceRoot, Future<T> Function() action) {
    final Completer<T> result = Completer<T>();

    final Future<void> previous =
        _tails[workspaceRoot] ?? Future<void>.value();

    // 队尾接的是 `result.future` 的"完成与否"，而不是它本身：用
    // `.then` 串会让异常沿着队列一路传下去，把后来者一并毒死。
    final Future<void> tail = previous.then((_) async {
      try {
        result.complete(await action());
      } on Object catch (e, stack) {
        result.completeError(e, stack);
      }
    });

    _tails[workspaceRoot] = tail;

    // 队列空了就把键删掉，否则每个用过的会话都会留一个永不回收的 entry。
    unawaited(
      tail.whenComplete(() {
        if (identical(_tails[workspaceRoot], tail)) {
          _tails.remove(workspaceRoot);
        }
      }),
    );

    return result.future;
  }
}
