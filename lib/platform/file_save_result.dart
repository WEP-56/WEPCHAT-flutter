/// 文件导出结果。取消与失败分开，界面只展示经过脱敏的说明。
sealed class FileSaveResult {
  const FileSaveResult(this.message);
  final String message;
}

class FileSaved extends FileSaveResult {
  const FileSaved(super.message);
}

class FileSaveCancelled extends FileSaveResult {
  const FileSaveCancelled() : super('已取消导出');
}

class FileSaveFailed extends FileSaveResult {
  const FileSaveFailed(super.message);
}
