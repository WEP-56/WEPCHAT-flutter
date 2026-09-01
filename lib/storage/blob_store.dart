import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/errors.dart';

/// 一次 GC 的结果。
class BlobGcResult {
  const BlobGcResult({
    required this.unreferencedRemoved,
    required this.orphanFilesRemoved,
  });

  /// 引用计数归零、行与文件都被删掉的 blob 数。
  final int unreferencedRemoved;

  /// 有文件但表里没有对应行的孤儿文件数。
  ///
  /// 来源是"文件已写、事务回滚"的窗口——写文件不在事务保护范围内。
  final int orphanFilesRemoved;

  bool get isEmpty => unreferencedRemoved == 0 && orphanFilesRemoved == 0;

  @override
  String toString() =>
      'BlobGcResult(unreferenced=$unreferencedRemoved, '
      'orphanFiles=$orphanFilesRemoved)';
}

/// 内容寻址的二进制存储（存储设计 §4 §5.3）。
///
/// 布局：`<root>/<sha256 前 2 位>/<sha256>`。分两级目录避免单目录下
/// 上万个文件——Android 的部分文件系统在这种情况下 `readdir` 会明显变慢。
///
/// blob 与工作区文件的职责不同：工作区文件是**用户产物**，可被用户改名删除；
/// blob 是**进入过上下文的字节**，历史渲染和重发请求都需要当初那份字节。
/// 所以入库时按内容哈希复制一份，不引用工作区路径。
///
/// 只在 DB isolate 内使用：这里的文件 IO 是同步的，放在 UI isolate 会卡帧
/// （AGENTS.md §5.3）。
class BlobStore {
  BlobStore(this._db, this._root);

  final Database _db;

  /// blob 根目录，通常是 `<App 私有目录>/blobs`。
  final Directory _root;

  /// 写入字节并登记引用。返回 sha256 十六进制。
  ///
  /// 同一份字节重复写入只落一份文件（内容寻址天然去重），但每个引用位置
  /// 都会在 `blob_refs` 里登记一行，GC 靠它判断是否还有人用。
  String put(
    Uint8List bytes, {
    required String mime,
    required String sessionId,
    required int seq,
  }) {
    final String sha = sha256.convert(bytes).toString();
    final File target = _fileFor(sha);

    if (!target.existsSync()) {
      target.parent.createSync(recursive: true);
      // 先写临时文件再 rename：直接写目标路径时若中途断电，会留下一个
      // 内容不完整但文件名声称是某个哈希的文件，后续读取拿到坏字节且
      // 无法察觉。rename 在同一分区上是原子的。
      final File tmp = File('${target.path}.tmp');
      tmp.writeAsBytesSync(bytes, flush: true);
      tmp.renameSync(target.path);
    }

    _db.execute(
      'INSERT OR IGNORE INTO blobs (sha256, bytes, mime, created_at) '
      'VALUES (?, ?, ?, ?)',
      <Object?>[
        sha,
        bytes.lengthInBytes,
        mime,
        DateTime.now().millisecondsSinceEpoch,
      ],
    );
    _db.execute(
      'INSERT OR IGNORE INTO blob_refs (sha256, session_id, seq) '
      'VALUES (?, ?, ?)',
      <Object?>[sha, sessionId, seq],
    );

    return sha;
  }

  /// 读回字节。文件缺失是数据损坏，明确报错而不是返回空
  /// （AGENTS.md §1.3）。
  Uint8List read(String sha256Hex) {
    final File f = _fileFor(sha256Hex);
    if (!f.existsSync()) {
      throw StorageError(
        'blob 文件缺失，数据可能已损坏',
        context: <String, Object?>{'sha256': sha256Hex},
      );
    }
    return f.readAsBytesSync();
  }

  bool exists(String sha256Hex) => _fileFor(sha256Hex).existsSync();

  /// 删掉一个会话的全部引用。会话删除流程的一步（存储设计 §9-11）。
  ///
  /// 只删引用不删 blob——同一份字节可能被别的会话引用着。真正的删除
  /// 由 [collectGarbage] 做。
  void removeSessionRefs(String sessionId) {
    _db.execute('DELETE FROM blob_refs WHERE session_id = ?', <Object?>[
      sessionId,
    ]);
  }

  /// GC：删掉没有引用的 blob，以及表里没有记录的孤儿文件。
  ///
  /// 顺序是**先删表行、再删文件**。反过来会在两步之间留下"有记录无文件"
  /// 的悬挂引用，那种状态下 [read] 会抛错，而且无法自愈；先删行的话
  /// 中途失败只留下孤儿文件，下一轮 GC 能扫掉。
  BlobGcResult collectGarbage() {
    final ResultSet unreferenced = _db.select('''
SELECT b.sha256 FROM blobs b
LEFT JOIN blob_refs r ON r.sha256 = b.sha256
WHERE r.sha256 IS NULL''');

    final List<String> shas = unreferenced
        .map((Row r) => r['sha256'] as String)
        .toList(growable: false);

    for (final String sha in shas) {
      _db.execute('DELETE FROM blobs WHERE sha256 = ?', <Object?>[sha]);
    }
    for (final String sha in shas) {
      final File f = _fileFor(sha);
      if (f.existsSync()) f.deleteSync();
    }

    return BlobGcResult(
      unreferencedRemoved: shas.length,
      orphanFilesRemoved: _removeOrphanFiles(),
    );
  }

  /// 扫盘删掉表里没有记录的文件。
  ///
  /// 这些是"文件已写、事务随后回滚"留下的——写文件不受事务保护。
  int _removeOrphanFiles() {
    if (!_root.existsSync()) return 0;

    final ResultSet rows = _db.select('SELECT sha256 FROM blobs');
    final Set<String> known = rows
        .map((Row r) => r['sha256'] as String)
        .toSet();

    int removed = 0;
    for (final FileSystemEntity entity in _root.listSync(recursive: true)) {
      if (entity is! File) continue;
      final String name = p.basename(entity.path);

      // `.tmp` 是写入中断留下的半成品，一并清掉。
      if (name.endsWith('.tmp')) {
        entity.deleteSync();
        removed++;
        continue;
      }
      if (!known.contains(name)) {
        entity.deleteSync();
        removed++;
      }
    }
    return removed;
  }

  /// 校验后拼路径。哈希是内部产生的，但它也会从 `entries.payload` 读回来
  /// ——那是磁盘上的数据，损坏或被改动后不能直接拿去拼路径。
  File _fileFor(String sha256Hex) {
    if (!_sha256Hex.hasMatch(sha256Hex)) {
      throw StorageError(
        'sha256 格式非法，拒绝拼接路径',
        context: <String, Object?>{
          'value': sha256Hex,
          'length': sha256Hex.length,
        },
      );
    }
    return File(p.join(_root.path, sha256Hex.substring(0, 2), sha256Hex));
  }

  static final RegExp _sha256Hex = RegExp(r'^[0-9a-f]{64}$');
}
