import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/browser/browser_page.dart';

void main() {
  test('工作区文件使用 file URI 而不是 Flutter asset 路径', () {
    final Uri uri = browserFileUri(
      '/data/user/0/com.wep.wepchat/files/workspaces/s1/example.html',
      windows: false,
    );

    expect(uri.scheme, equals('file'));
    expect(uri.path, endsWith('/example.html'));
    expect(uri.toString(), startsWith('file:///data/'));
  });

  test('空文件路径直接报参数错误', () {
    expect(() => browserFileUri('  ', windows: false), throwsArgumentError);
  });
}
