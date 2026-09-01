/// 工具注册表（实施 TODO §7-2、§7-3）。
library;

import '../ai/provider_api.dart';
import '../core/cancellation_token.dart';
import '../core/errors.dart';
import 'tool.dart';

/// 工具的查找与声明排序。
///
/// 排序在这里做一次，适配器不再排（`ProviderRequest.tools` 的注释说明了
/// 这个分工）。理由是缓存前缀依赖字节稳定：两处各排一次，哪天其中一处的
/// 比较函数变了，缓存会静默失效而不报错——静默失效只能靠对账单发现。
class ToolRegistry {
  ToolRegistry(Iterable<Tool> tools)
      : _byName = <String, Tool>{
          for (final Tool t in tools) t.name: t,
        } {
    if (_byName.length != tools.length) {
      final List<String> names = tools.map((Tool t) => t.name).toList()..sort();
      throw StorageError(
        '工具名重复',
        context: <String, Object?>{'names': names.join(', ')},
      );
    }
  }

  /// 空注册表。没配工具的会话用它，`declarations` 为空则请求体不带
  /// `tools` 字段。
  static final ToolRegistry empty = ToolRegistry(const <Tool>[]);

  final Map<String, Tool> _byName;

  /// 按名字典序排好的声明，直接传给 [ProviderRequest.tools]（§6-6）。
  List<ToolDefinition> get declarations {
    final List<Tool> sorted = _byName.values.toList()
      ..sort((Tool a, Tool b) => a.name.compareTo(b.name));
    return sorted.map((Tool t) => t.definition).toList(growable: false);
  }

  bool contains(String name) => _byName.containsKey(name);

  Tool? find(String name) => _byName[name];

  /// 执行一次工具调用。
  ///
  /// 模型给的工具名可能不存在（拼错、或是换模型后旧历史里的工具已经下线）。
  /// 这种情况返回 [ToolResult.error] 而不是抛：模型看到"没有这个工具，可用
  /// 的是 x/y/z"就会自己改用对的那个（§7-5）。
  Future<ToolResult> dispatch(
    String name,
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    final Tool? tool = _byName[name];
    if (tool == null) {
      final List<String> available = _byName.keys.toList()..sort();
      return ToolResult.error(
        '没有名为 $name 的工具。可用的工具：${available.join('、')}',
      );
    }

    if (context.token.isCancelled) {
      return ToolResult.error('执行被用户中断');
    }

    try {
      return await tool.execute(arguments, context);
    } on CancelledException {
      // 中断不是工具的错，但也要作为结果回传：这一轮的 tool_use 必须配一个
      // tool_result，缺了下次请求会被 API 拒（§5-6）。
      return ToolResult.error('执行被用户中断');
    } on Object catch (e) {
      // 工具实现里漏掉的异常不能杀掉整个 loop——那会让用户看到一条没有
      // 结果的工具调用，且无法继续对话。
      return ToolResult.error('工具 $name 执行失败：$e');
    }
  }
}
