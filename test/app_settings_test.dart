import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/models/settings.dart';
import 'package:wepchat/state/app_settings.dart';

void main() {
  test('相同 category + key 视为更新，不重复制造条目（功能协议 §7.2）', () {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);
    final int before = settings.memories.length;

    settings.upsertMemory(
      category: '偏好',
      key: 'reply_language',
      value: '中文',
      updatedAt: '2026-08-30',
    );
    expect(settings.memories.length, before + 1);

    settings.upsertMemory(
      category: '偏好',
      key: 'reply_language',
      value: '中文，代码注释用英文',
      updatedAt: '2026-08-31',
    );
    expect(settings.memories.length, before + 1);

    final MemoryEntry entry = settings.memories.firstWhere(
      (MemoryEntry e) => e.category == '偏好' && e.key == 'reply_language',
    );
    expect(entry.value, '中文，代码注释用英文');
    expect(entry.updatedAt, '2026-08-31');
  });

  test('未声明的工具不会给出默认权限，而是抛错', () {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);

    expect(() => settings.permissionOf('rm_rf'), throwsArgumentError);
    expect(
      () => settings.setPermission('rm_rf', ToolPermission.allowed),
      throwsArgumentError,
    );
  });

  test('工具权限有默认档位并且可以修改', () {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);

    settings.setPermission('write_file', ToolPermission.denied);
    expect(settings.permissionOf('write_file'), ToolPermission.denied);
  });

  test('空的工作区根目录不会覆盖原值', () {
    final AppSettings settings = AppSettings.memory();
    addTearDown(settings.dispose);
    final String original = settings.workspaceRoot;

    settings.setWorkspaceRoot('   ');
    expect(settings.workspaceRoot, original);

    settings.setWorkspaceRoot(r'  D:\WePChat\ws  ');
    expect(settings.workspaceRoot, r'D:\WePChat\ws');
  });
}
