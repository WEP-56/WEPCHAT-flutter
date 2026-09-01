/// WePChat 错误体系基类。所有领域错误继承此类，禁止裸 Exception。
///
/// 设计原则（AGENTS.md §1.3）：
/// - 错误在最接近失败的位置转换为有意义的领域错误
/// - 不使用空 catch、不吞掉异常、不伪造成功结果
/// - 错误必须带有来源和上下文
abstract class WepError implements Exception {
  const WepError(this.message, {this.context});

  final String message;
  final Map<String, Object?>? context;

  @override
  String toString() {
    final StringBuffer buf = StringBuffer()
      ..write(runtimeType)
      ..write(': ')
      ..write(message);
    if (context != null && context!.isNotEmpty) {
      buf.write(' (');
      buf.writeAll(
        context!.entries.map(
          (MapEntry<String, Object?> e) => '${e.key}=${e.value}',
        ),
        ', ',
      );
      buf.write(')');
    }
    return buf.toString();
  }
}

/// 网络请求失败。
class NetworkError extends WepError {
  const NetworkError(super.message, {super.context});
}

/// API 返回错误响应。
class ApiError extends WepError {
  const ApiError(
    super.message, {
    required this.statusCode,
    this.providerMessage,
    super.context,
  });

  final int statusCode;
  final String? providerMessage;

  @override
  String toString() {
    final String base = 'ApiError($statusCode): $message';
    if (providerMessage != null) return '$base — $providerMessage';
    return base;
  }
}

/// 认证失败（401、403、invalid key）。
class AuthError extends WepError {
  const AuthError(super.message, {super.context});
}

/// 工具执行失败（业务层面的失败，如文件不存在）。
class ToolError extends WepError {
  const ToolError(super.message, {super.context});
}

/// 权限被拒绝（用户拒绝了工具调用）。
class PermissionDeniedError extends WepError {
  const PermissionDeniedError(super.message, {super.context});
}

/// 存储层失败（数据库、文件系统）。
class StorageError extends WepError {
  const StorageError(super.message, {super.context});
}

/// 参数校验失败。
class ValidationError extends WepError {
  const ValidationError(super.message, {super.context});
}
