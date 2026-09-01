import 'dart:math';

/// ULID 生成器（时间前缀 + 随机）。
///
/// 格式：26 字符，Crockford base32，前 10 位是时间戳（ms），后 16 位随机。
/// 优点：按时间排序、URL 安全、比 UUID 短。
///
/// 用于会话 id、条目 id、工具调用 id。
///
/// 排序粒度是毫秒：同一毫秒内生成的两个 ULID 时间前缀相同，字典序由随机段
/// 决定，因此**不保证**严格单调。会话内的顺序由 `entries.seq` 保证
/// （存储设计 §5.2），id 只需要唯一，所以不实现 monotonic 变体。
class Ulid {
  Ulid._();

  static final Random _random = Random.secure();

  /// Crockford base32 字符集（不含 I L O U，避免混淆）。
  static const String _encoding = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

  /// 生成一个新的 ULID。
  static String generate() {
    final int timestamp = DateTime.now().millisecondsSinceEpoch;
    final StringBuffer buf = StringBuffer();

    // 前 10 位：时间戳（48 bit，约 8000 年）
    _encodeTime(timestamp, buf);

    // 后 16 位：随机（80 bit）
    for (int i = 0; i < 16; i++) {
      buf.write(_encoding[_random.nextInt(32)]);
    }

    return buf.toString();
  }

  static void _encodeTime(int timestamp, StringBuffer buf) {
    int t = timestamp;
    // 48 bit = 10 个 base32 字符（每字符 5 bit，实际用 50 bit，时间戳只占 48）
    final List<int> digits = List<int>.filled(10, 0);
    for (int i = 9; i >= 0; i--) {
      digits[i] = t & 0x1F;
      t = t >> 5;
    }
    for (final int d in digits) {
      buf.write(_encoding[d]);
    }
  }

  /// 从 ULID 提取时间戳（用于调试，业务层一般不需要）。
  static DateTime? parseTime(String ulid) {
    if (ulid.length != 26) return null;
    try {
      int timestamp = 0;
      for (int i = 0; i < 10; i++) {
        final int val = _encoding.indexOf(ulid[i].toUpperCase());
        if (val < 0) return null;
        timestamp = (timestamp << 5) | val;
      }
      return DateTime.fromMillisecondsSinceEpoch(timestamp);
    } catch (_) {
      return null;
    }
  }
}
