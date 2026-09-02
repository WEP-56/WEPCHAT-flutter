/// 工具权限门（实施 TODO §7-10 ~ §7-12，功能协议 §9）。
///
/// 每次工具执行**之前**过这里。三态设置来自用户的全局配置，`ask` 会弹窗，
/// 弹窗的答案可以在本会话内记住。
library;

import '../models/settings.dart';
import '../state/app_settings.dart';
import 'tool.dart';

/// 弹窗要展示的内容。
class PermissionRequest {
  const PermissionRequest({
    required this.sessionId,
    required this.toolName,
    required this.permissionId,
    required this.arguments,
  });

  final String sessionId;

  /// 模型调用的工具名，例如 `write_file`。
  final String toolName;

  /// 对应的权限设置 id（`kToolPermissionSpecs`）。多个工具可能共用一条。
  final String permissionId;

  /// 未经删改的原始参数。弹窗自己决定摘要成什么样
  /// （`summarizeToolArguments`）。
  final Map<String, Object?> arguments;
}

/// 用户在弹窗里的回答。
class PermissionAnswer {
  const PermissionAnswer({required this.allowed, this.remember = false});

  const PermissionAnswer.allowOnce() : allowed = true, remember = false;
  const PermissionAnswer.allowAlways() : allowed = true, remember = true;
  const PermissionAnswer.reject() : allowed = false, remember = false;

  final bool allowed;

  /// 「本会话内一直允许」。
  ///
  /// 这个记忆是**运行时的，不落 entries**（§7-11）：它不是对话内容。
  /// 写进历史会让它跟着会话被永久重放，用户下次打开这个会话时还在生效，
  /// 而他当初同意的只是"接下来这一小段"。
  final bool remember;
}

/// 问用户。返回 null 表示没人能回答（界面还没接上），按拒绝处理。
typedef PermissionPrompt =
    Future<PermissionAnswer?> Function(PermissionRequest request);

/// 一次裁决的结果。
class PermissionVerdict {
  const PermissionVerdict.allow() : allowed = true, reason = '';
  const PermissionVerdict.deny(this.reason) : allowed = false;

  final bool allowed;

  /// 拒绝时给模型的说明。要让它知道是被**用户**拒了，不是执行失败——
  /// 否则它会换个参数把同一件事再试一遍（§7-12）。
  final String reason;
}

/// 权限门。
///
/// 一个实例服务所有会话：「本会话内一直允许」按 `会话 id + 权限 id` 记，
/// 而不是给每个会话各建一个门——那样切会话时得记得换实例，忘了就等于
/// 把 A 会话的授权带到了 B 会话。
class PermissionGate {
  PermissionGate({required AppSettings settings, PermissionPrompt? prompt})
    : _settings = settings,
      _prompt = prompt;

  final AppSettings _settings;
  final PermissionPrompt? _prompt;

  final Set<String> _rememberedAllows = <String>{};

  /// 设置里配的档位，不问用户、不看会话记忆。
  ToolPermission check(String permissionId) {
    return _settings.permissionOrAsk(permissionId);
  }

  /// 裁决一次调用，必要时弹窗。
  ///
  /// 返回二态而不是三态：`ask` 在这里面已经问完了。调用方拿到 `ask` 却忘了
  /// 处理，默认行为会变成放行——所以不给它这个机会（§7-10）。
  Future<PermissionVerdict> authorize({
    required Tool tool,
    required String sessionId,
    required Map<String, Object?> arguments,
  }) async {
    final String permissionId = tool.permissionId;

    switch (check(permissionId)) {
      case ToolPermission.allowed:
        return const PermissionVerdict.allow();
      case ToolPermission.denied:
        return PermissionVerdict.deny(
          '用户在设置里禁用了「${_labelOf(permissionId)}」，'
          '这个工具本次不可用。请改用别的方式，或告诉用户去设置里开启。',
        );
      case ToolPermission.ask:
        break;
    }

    if (_rememberedAllows.contains(_memoryKey(sessionId, permissionId))) {
      return const PermissionVerdict.allow();
    }

    final PermissionPrompt? prompt = _prompt;
    if (prompt == null) {
      // 没有界面可问（headless 测试、后台任务）。默认方向必须是拒绝：
      // 「问不到人所以放行」正是权限门要防的那件事。
      return PermissionVerdict.deny(
        '「${_labelOf(permissionId)}」需要用户确认，但当前没有可用的确认界面。',
      );
    }

    final PermissionAnswer? answer = await prompt(
      PermissionRequest(
        sessionId: sessionId,
        toolName: tool.name,
        permissionId: permissionId,
        arguments: arguments,
      ),
    );

    if (answer == null || !answer.allowed) {
      return PermissionVerdict.deny(
        '用户拒绝了这次「${_labelOf(permissionId)}」调用。'
        '不要重试同一个操作，换个思路或直接询问用户。',
      );
    }

    if (answer.remember) {
      _rememberedAllows.add(_memoryKey(sessionId, permissionId));
    }
    return const PermissionVerdict.allow();
  }

  /// 会话被删除时清掉它的授权记忆。
  void forgetSession(String sessionId) {
    _rememberedAllows.removeWhere(
      (String key) => key.startsWith('$sessionId/'),
    );
  }

  /// 这个会话是否已经对某档位选过「一直允许」。界面据此显示提示。
  bool isRemembered(String sessionId, String permissionId) {
    return _rememberedAllows.contains(_memoryKey(sessionId, permissionId));
  }

  static String _memoryKey(String sessionId, String permissionId) {
    return '$sessionId/$permissionId';
  }

  /// 权限档位的中文名。给模型的拒绝说明里用它而不是 id：
  /// 模型要转述给用户听，说"写入文件"比说 "write_file" 好懂。
  static String _labelOf(String permissionId) {
    for (final ToolPermissionSpec spec in kToolPermissionSpecs) {
      if (spec.id == permissionId) return spec.name;
    }
    return permissionId;
  }
}
