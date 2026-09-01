import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../core/errors.dart';

/// `entries.payload` 的编码方式（存储设计 §5.2 §9-4）。
enum PayloadEncoding {
  /// 明文 UTF-8 JSON。小条目走这条，可调试性优先。
  json('json'),

  /// gzip 压缩的 UTF-8 JSON。
  gzip('gzip'),

  /// payload 列存 sha256 十六进制，真实字节在 blob 目录里。
  external('external');

  const PayloadEncoding(this.wire);

  /// 落库的字符串值。不用 `enum.name` 是为了让重命名 Dart 标识符
  /// 不会改变已经写进库里的值。
  final String wire;

  static PayloadEncoding fromWire(String wire) {
    for (final PayloadEncoding e in PayloadEncoding.values) {
      if (e.wire == wire) return e;
    }
    throw StorageError(
      '未知的 payload 编码',
      context: <String, Object?>{'encoding': wire},
    );
  }
}

/// 超过这个大小就 gzip。4 KB 以下压缩收益抵不上 CPU 与可调试性损失。
const int kGzipThresholdBytes = 4 * 1024;

/// 超过这个大小不进库，落 blob 目录。
///
/// 理由：巨大单行会拉长 SQLite 的溢出页链，拖慢同一会话所有条目的区间扫描。
const int kExternalThresholdBytes = 256 * 1024;

/// 编码结果。[encoding] 为 [PayloadEncoding.external] 时 [bytes] 是
/// 待写入 blob 的原始 JSON 字节，调用方负责写盘并把 sha256 存进 payload 列。
class EncodedPayload {
  const EncodedPayload({
    required this.encoding,
    required this.bytes,
    required this.plainBytes,
  });

  final PayloadEncoding encoding;

  /// 直接写进 `entries.payload` 的字节（external 时由调用方替换为 sha256）。
  final Uint8List bytes;

  /// 未压缩的 JSON 字节数，用于阈值判断与统计。
  final int plainBytes;
}

/// payload 编解码。三态判断只在这里实现一次（AGENTS.md §1.2）。
class PayloadCodec {
  const PayloadCodec();

  /// 把消息本体编码成可落库的字节。
  ///
  /// 阈值按**未压缩**字节数判断，这样同一条 payload 的编码方式不依赖
  /// 压缩率，重放时可预测。
  EncodedPayload encode(Map<String, Object?> payload) {
    final Uint8List plain = _utf8Json(payload);

    if (plain.lengthInBytes >= kExternalThresholdBytes) {
      return EncodedPayload(
        encoding: PayloadEncoding.external,
        bytes: plain,
        plainBytes: plain.lengthInBytes,
      );
    }

    if (plain.lengthInBytes >= kGzipThresholdBytes) {
      return EncodedPayload(
        encoding: PayloadEncoding.gzip,
        bytes: Uint8List.fromList(gzip.encode(plain)),
        plainBytes: plain.lengthInBytes,
      );
    }

    return EncodedPayload(
      encoding: PayloadEncoding.json,
      bytes: plain,
      plainBytes: plain.lengthInBytes,
    );
  }

  /// 解码 `json` / `gzip` 两态。
  ///
  /// `external` 不在这里处理——它需要读 blob 目录，是 IO 操作，
  /// 由 DAO 取到字节后调用 [decodeBytes]。
  Map<String, Object?> decode(PayloadEncoding encoding, Uint8List stored) {
    switch (encoding) {
      case PayloadEncoding.json:
        return decodeBytes(stored);
      case PayloadEncoding.gzip:
        return decodeBytes(Uint8List.fromList(gzip.decode(stored)));
      case PayloadEncoding.external:
        throw const StorageError(
          'external payload 必须先从 blob 读出字节再调用 decodeBytes',
        );
    }
  }

  /// 解码未压缩的 JSON 字节。
  Map<String, Object?> decodeBytes(Uint8List plain) {
    final Object? decoded = jsonDecode(utf8.decode(plain));
    if (decoded is! Map<String, Object?>) {
      throw StorageError(
        'payload 不是 JSON 对象',
        context: <String, Object?>{'actualType': decoded.runtimeType},
      );
    }
    return decoded;
  }

  /// external 编码时 `payload` 列存的是 sha256 十六进制字符串。
  Uint8List encodeExternalRef(String sha256Hex) =>
      Uint8List.fromList(utf8.encode(sha256Hex));

  String decodeExternalRef(Uint8List stored) => utf8.decode(stored);

  /// 确定性 JSON 序列化。
  ///
  /// Dart 的 `Map` 是插入序，`jsonEncode` 按插入序输出，所以**构造 Map 的
  /// 代码顺序决定了字节**。这里不重排键：payload 的字节稳定性依赖调用方
  /// 用固定顺序构造 Map（实施 TODO §6-5）。重排反而会掩盖上游的不确定性。
  Uint8List _utf8Json(Map<String, Object?> payload) =>
      Uint8List.fromList(utf8.encode(jsonEncode(payload)));
}
