/// 设置的持久化：App 私有目录下的一个 JSON 文件（实施 TODO §13.4）。
///
/// 决定的理由：这是个轻量项目。Android 私有目录未 root 拿不到；Windows 上
/// 明文可读，要改善得写 DPAPI 平台通道，工作量与收益不成比例。将来要加密
/// 只需换这个类的 [read] / [write] 两个方法，调用方不动。
///
/// 不进 SQLite 的理由：设置要在首帧之前就绪，而 DB 走 isolate 往返；
/// 而且设置是"最后写的赢"的整体覆盖，没有 append-only 的需求。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../core/errors.dart';

/// 读写一个 JSON 文件。
///
/// 只负责序列化与落盘的机制，不认识任何具体设置项——那是 `AppSettings`
/// 的事。这样加一个设置项不需要改这个文件。
class SettingsStore {
  SettingsStore(this._file);

  /// 用于测试：指向临时目录里的文件。
  factory SettingsStore.atPath(String path) => SettingsStore(File(path));

  final File _file;

  String get path => _file.path;

  /// 读出整个设置 Map。文件不存在时返回空 Map（首次启动的正常情况）。
  ///
  /// 抛 [StorageError]：文件存在但不是合法 JSON 对象。**不静默返回默认值**
  /// ——那会让用户的配置在一次意外之后无声消失，而他只会觉得"key 又没了"。
  Map<String, Object?> read() {
    if (!_file.existsSync()) return <String, Object?>{};

    final String raw;
    try {
      raw = _file.readAsStringSync();
    } on FileSystemException catch (e) {
      throw StorageError(
        '读取设置文件失败',
        context: <String, Object?>{'path': _file.path, 'cause': e.message},
      );
    }

    if (raw.trim().isEmpty) return <String, Object?>{};

    final Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } on FormatException catch (e) {
      throw StorageError(
        '设置文件不是合法 JSON，已保留原文件。请修复或删除它。',
        context: <String, Object?>{'path': _file.path, 'cause': e.message},
      );
    }

    if (decoded is! Map<String, Object?>) {
      throw StorageError(
        '设置文件的顶层不是 JSON 对象',
        context: <String, Object?>{'path': _file.path},
      );
    }
    return decoded;
  }

  /// 写入整个设置 Map。
  ///
  /// 先写临时文件再 rename：直接覆写时如果进程在写一半时被杀，文件会变成
  /// 半个 JSON，下次启动 [read] 直接报错，用户的 key 就没了。rename 在同
  /// 一个卷内是原子的，两个平台都是。
  Future<void> write(Map<String, Object?> data) async {
    final File temp = File('${_file.path}.tmp');
    try {
      await _file.parent.create(recursive: true);
      // 缩进两格：这个文件用户可能自己去改（改 base url 之类），
      // 可读比省几个字节重要。
      await temp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(data),
        flush: true,
      );
      await temp.rename(_file.path);
    } on FileSystemException catch (e) {
      // 清掉临时文件，不然下次启动目录里躺着一个 .tmp 让人困惑。
      if (temp.existsSync()) {
        try {
          temp.deleteSync();
        } on FileSystemException {
          // 删不掉就算了，重要的是把原始失败抛出去。
        }
      }
      throw StorageError(
        '写入设置文件失败',
        context: <String, Object?>{'path': _file.path, 'cause': e.message},
      );
    }
  }
}
