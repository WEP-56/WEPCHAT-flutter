import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import '../models/document_preview.dart';
import '../models/workspace.dart';
import 'office_preview_parser.dart';
import 'workspace_guard.dart';

/// 预览文件的读取上限；读取、路径检查和解析均在可终止的 isolate 内。
const int kMaxDocumentPreviewBytes = 32 * 1024 * 1024;
const Duration kDocumentPreviewTimeout = Duration(seconds: 30);

class DocumentPreviewLoader {
  Isolate? _worker;
  ReceivePort? _port;
  Timer? _timer;
  Completer<DocumentPreview>? _result;

  Future<DocumentPreview> load(String root, String relative) {
    if (_result != null) throw StateError('每个预览加载器只能启动一次');
    final result = _result = Completer<DocumentPreview>();
    final port = _port = ReceivePort();
    port.listen((message) {
      if (message == null) return;
      if (message is DocumentPreview) {
        _finish(() => result.complete(message));
      } else if (message is DocumentPreviewException) {
        _finish(() => result.completeError(message));
      } else {
        _finish(
          () => result.completeError(
            const DocumentPreviewException('文档预览进程意外退出'),
          ),
        );
      }
    });
    _timer = Timer(
      kDocumentPreviewTimeout,
      () => _finish(
        () => result.completeError(const DocumentPreviewException('文档预览超时')),
      ),
    );
    unawaited(_spawn(root, relative, port.sendPort));
    return result.future;
  }

  Future<void> _spawn(String root, String relative, SendPort port) async {
    try {
      final worker = await Isolate.spawn(_load, (
        root,
        relative,
        port,
      ), onError: port);
      if (_result!.isCompleted) {
        worker.kill(priority: Isolate.immediate);
      } else {
        _worker = worker;
      }
    } on Object {
      _finish(
        () => _result!.completeError(
          const DocumentPreviewException('无法启动文档预览进程'),
        ),
      );
    }
  }

  void cancel() =>
      _finish(() => _result!.completeError(const DocumentPreviewCancelled()));

  void _finish(void Function() complete) {
    if (_result == null || _result!.isCompleted) return;
    _timer?.cancel();
    _worker?.kill(priority: Isolate.immediate);
    _port?.close();
    complete();
  }
}

void _load((String, String, SendPort) request) {
  final (root, relative, port) = request;
  try {
    final checked = WorkspaceGuard(root).check(relative);
    if (checked is! PathAllowed) {
      throw const DocumentPreviewException('预览失败：文件路径不在有效的会话工作区内');
    }
    final kind = fileKindFromName(relative);
    if (!{FileKind.pdf, FileKind.docx, FileKind.pptx}.contains(kind)) {
      throw const DocumentPreviewException('此文档格式暂不支持内置预览');
    }
    final handle = File(checked.absolute).openSync();
    late final DocumentPreview preview;
    try {
      if (handle.lengthSync() > kMaxDocumentPreviewBytes) {
        throw const DocumentPreviewException('文件超过 32 MB，无法内置预览');
      }
      final bytes = handle.readSync(kMaxDocumentPreviewBytes + 1);
      if (bytes.length > kMaxDocumentPreviewBytes) {
        throw const DocumentPreviewException('文件超过 32 MB，无法内置预览');
      }
      preview = kind == FileKind.pdf
          ? PdfPreview(bytes)
          : parseOfficePreview(bytes, slides: kind == FileKind.pptx);
    } finally {
      handle.closeSync();
    }
    Isolate.exit(port, preview);
  } on DocumentPreviewException catch (error) {
    port.send(error);
  } on FileSystemException {
    port.send(const DocumentPreviewException('文档读取失败：文件不存在或无法访问'));
  } on Object {
    port.send(const DocumentPreviewException('文档预览失败：文件内容无法处理'));
  }
}
