import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/core/ulid.dart';

void main() {
  group('Ulid', () {
    test('生成 26 字符的 ULID', () {
      final String ulid = Ulid.generate();
      expect(ulid.length, equals(26));
      expect(RegExp(r'^[0-9A-HJKMNP-TV-Z]{26}$').hasMatch(ulid), isTrue);
    });

    test('时间前缀单调不减（同毫秒内随机段不保证有序）', () {
      final String ulid1 = Ulid.generate();
      final String ulid2 = Ulid.generate();

      // 只比较前 10 位时间前缀。整串比较会在同一毫秒内随机失败，
      // 因为后 16 位是随机的（见 Ulid 文档注释）。
      expect(
        ulid2.substring(0, 10).compareTo(ulid1.substring(0, 10)) >= 0,
        isTrue,
      );
    });

    test('生成的 ULID 不重复（概率极低）', () {
      final Set<String> ulids = <String>{};
      for (int i = 0; i < 100; i++) {
        ulids.add(Ulid.generate());
      }
      expect(ulids.length, equals(100));
    });

    test('parseTime() 可以提取时间戳', () {
      final DateTime before = DateTime.now();
      final String ulid = Ulid.generate();
      final DateTime after = DateTime.now();

      final DateTime? parsed = Ulid.parseTime(ulid);
      expect(parsed, isNotNull);
      expect(
        parsed!.millisecondsSinceEpoch >= before.millisecondsSinceEpoch &&
            parsed.millisecondsSinceEpoch <= after.millisecondsSinceEpoch,
        isTrue,
      );
    });

    test('parseTime() 对无效 ULID 返回 null', () {
      expect(Ulid.parseTime(''), isNull);
      expect(Ulid.parseTime('short'), isNull);
      expect(Ulid.parseTime('01234567890123456789012345!'), isNull);
    });
  });
}
