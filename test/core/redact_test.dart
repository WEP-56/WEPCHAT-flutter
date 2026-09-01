import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/core/redact.dart';

void main() {
  group('redact', () {
    test('脱敏 sk- 开头的 API key', () {
      const String text = 'Using key: sk-abc123XYZ_test_key_value';
      expect(redact(text), equals('Using key: <REDACTED_API_KEY>'));
    });

    test('脱敏整条 Authorization 头，连 scheme 一起', () {
      const String text =
          'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9';
      final String result = redact(text);

      expect(result, equals('Authorization: <REDACTED>'));
      expect(result, isNot(contains('eyJhbGciOi')));
    });

    test('脱敏 Basic 认证头', () {
      const String text = 'Authorization: Basic dXNlcjpwYXNz';
      expect(redact(text), equals('Authorization: <REDACTED>'));
    });

    test('脱敏不在 Authorization 头里的 Bearer token', () {
      const String text = 'retry with token=Bearer abcdefghijklmnop123';
      final String result = redact(text);

      expect(result, contains('Bearer <REDACTED_TOKEN>'));
      expect(result, isNot(contains('abcdefghijklmnop123')));
    });

    test('Bearer 大小写不敏感', () {
      expect(redact('bearer abcdefghijklmnop01'), contains('<REDACTED_TOKEN>'));
      expect(redact('BEARER xyzuvwrstqponmlk02'), contains('<REDACTED_TOKEN>'));
    });

    test('脱敏 Windows 路径的用户名，保留盘符与大小写', () {
      expect(
        redact(r'File at C:\Users\Alice\Documents\file.txt'),
        equals(r'File at C:\Users\<USER>\Documents\file.txt'),
      );
      expect(
        redact(r'open d:\users\Bob\wepchat.db'),
        equals(r'open d:\users\<USER>\wepchat.db'),
      );
    });

    test('脱敏 Unix 路径的用户名', () {
      const String text = 'Path: /home/bob/.config/app.json';
      expect(redact(text), equals('Path: /home/<USER>/.config/app.json'));
    });

    test('多个敏感信息同时脱敏', () {
      const String text =
          'key=sk-test1234567890abcdefgh, tok=Bearer abc.def.ghijklmnop, path=/home/user/file';
      final String result = redact(text);

      expect(result, isNot(contains('sk-test1234567890abcdefgh')));
      expect(result, isNot(contains('abc.def.ghijklmnop')));
      expect(result, isNot(contains('/home/user/')));
      expect(result, contains('<REDACTED_API_KEY>'));
      expect(result, contains('<REDACTED_TOKEN>'));
      expect(result, contains('/home/<USER>/'));
    });

    test('不改变不含敏感信息的文本', () {
      const String text = 'Normal log message with no secrets';
      expect(redact(text), equals(text));
    });

    test('幂等：脱敏两次结果相同', () {
      const String text =
          r'sk-abcdefghij1234567890 at C:\Users\Carol\app and Authorization: Bearer zzzzzzzzzzzzzzzzzz';
      final String once = redact(text);

      expect(redact(once), equals(once));
    });
  });
}
