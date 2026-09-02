import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/models/settings.dart';
import 'package:wepchat/state/app_settings.dart';
import 'package:wepchat/tools/permission_gate.dart';
import 'package:wepchat/tools/tool.dart';

/// 权限门（实施 TODO §7-10 ~ §7-12，功能协议 §9）。
///
/// 这一层唯一的职责是"不该放行的绝不放行"，所以每条测试都在问同一个问题：
/// 出错时默认方向是不是拒绝。
class _FakeTool extends Tool {
  const _FakeTool(this._permissionId);

  final String _permissionId;

  @override
  ToolDefinition get definition => ToolDefinition(
    name: 'fake_$_permissionId',
    description: '测试用',
    schema: const <String, Object?>{'type': 'object'},
  );

  @override
  String get permissionId => _permissionId;

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async => ToolResult.ok('ran');
}

void main() {
  late AppSettings settings;

  setUp(() => settings = AppSettings.memory());
  tearDown(() => settings.dispose());

  const _FakeTool readTool = _FakeTool('read_file');
  const _FakeTool writeTool = _FakeTool('write_file');

  Future<PermissionVerdict> authorize(
    PermissionGate gate,
    Tool tool, {
    String sessionId = 's1',
  }) {
    return gate.authorize(
      tool: tool,
      sessionId: sessionId,
      arguments: <String, Object?>{'path': 'a.txt'},
    );
  }

  group('三态', () {
    test('allowed 直接放行，不弹窗', () async {
      bool asked = false;
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async {
          asked = true;
          return const PermissionAnswer.allowOnce();
        },
      );

      // read_file 的默认档位就是「允许」（协议 §9 的表）。
      final PermissionVerdict v = await authorize(gate, readTool);

      expect(v.allowed, isTrue);
      expect(asked, isFalse);
    });

    test('denied 直接拒，不弹窗，理由指向设置页', () async {
      settings.setPermission('write_file', ToolPermission.denied);
      bool asked = false;
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async {
          asked = true;
          return const PermissionAnswer.allowOnce();
        },
      );

      final PermissionVerdict v = await authorize(gate, writeTool);

      expect(v.allowed, isFalse);
      expect(asked, isFalse);
      expect(v.reason, contains('设置'));
    });

    test('ask 会弹窗，用户同意则放行', () async {
      // write_file 的默认档位是「询问」。
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async =>
            const PermissionAnswer.allowOnce(),
      );

      expect((await authorize(gate, writeTool)).allowed, isTrue);
    });

    test('ask 且用户拒绝时，理由告诉模型别重试', () async {
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async => const PermissionAnswer.reject(),
      );

      final PermissionVerdict v = await authorize(gate, writeTool);

      expect(v.allowed, isFalse);
      // 模型看不出"是用户拒的"就会换个参数一遍遍重试同一件事。
      expect(v.reason, contains('拒绝'));
      expect(v.reason, contains('不要重试'));
    });
  });

  group('默认方向是拒绝', () {
    test('没有弹窗入口时 ask 按拒绝处理', () async {
      final PermissionGate gate = PermissionGate(settings: settings);
      final PermissionVerdict v = await authorize(gate, writeTool);

      expect(v.allowed, isFalse, reason: '问不到人所以放行，正是权限门要防的');
    });

    test('弹窗返回 null（被关掉）按拒绝处理', () async {
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async => null,
      );

      expect((await authorize(gate, writeTool)).allowed, isFalse);
    });

    test('未声明的 permissionId 退到「询问」而不是放行', () async {
      const _FakeTool unknown = _FakeTool('brand_new_tool');
      final PermissionGate gate = PermissionGate(settings: settings);

      expect(gate.check('brand_new_tool'), ToolPermission.ask);
      // 没有弹窗入口 → 拒。新工具忘了登记不会变成默认放行。
      expect((await authorize(gate, unknown)).allowed, isFalse);
    });
  });

  group('本会话一直允许', () {
    test('记住之后同会话不再弹窗', () async {
      int asked = 0;
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async {
          asked++;
          return const PermissionAnswer.allowAlways();
        },
      );

      expect((await authorize(gate, writeTool)).allowed, isTrue);
      expect((await authorize(gate, writeTool)).allowed, isTrue);
      expect(asked, equals(1));
      expect(gate.isRemembered('s1', 'write_file'), isTrue);
    });

    test('只允许一次的话下次还要问', () async {
      int asked = 0;
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async {
          asked++;
          return const PermissionAnswer.allowOnce();
        },
      );

      await authorize(gate, writeTool);
      await authorize(gate, writeTool);
      expect(asked, equals(2));
      expect(gate.isRemembered('s1', 'write_file'), isFalse);
    });

    test('记忆不跨会话', () async {
      int asked = 0;
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async {
          asked++;
          return const PermissionAnswer.allowAlways();
        },
      );

      await authorize(gate, writeTool, sessionId: 's1');
      await authorize(gate, writeTool, sessionId: 's2');
      expect(asked, equals(2), reason: 'A 会话的授权不该带到 B 会话');
    });

    test('会话被删时授权一并清掉', () async {
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async =>
            const PermissionAnswer.allowAlways(),
      );

      await authorize(gate, writeTool);
      expect(gate.isRemembered('s1', 'write_file'), isTrue);

      gate.forgetSession('s1');
      expect(gate.isRemembered('s1', 'write_file'), isFalse);
    });

    test('设置改成禁止后，会话内的旧授权不再生效', () async {
      final PermissionGate gate = PermissionGate(
        settings: settings,
        prompt: (PermissionRequest _) async =>
            const PermissionAnswer.allowAlways(),
      );

      await authorize(gate, writeTool);
      settings.setPermission('write_file', ToolPermission.denied);

      // 全局设置压过会话记忆：用户去设置里关掉，就是要它立刻停。
      expect((await authorize(gate, writeTool)).allowed, isFalse);
    });
  });

  test('弹窗拿到的是未经删改的原始参数', () async {
    Map<String, Object?>? seen;
    String? seenTool;
    final PermissionGate gate = PermissionGate(
      settings: settings,
      prompt: (PermissionRequest r) async {
        seen = r.arguments;
        seenTool = r.toolName;
        return const PermissionAnswer.allowOnce();
      },
    );

    await gate.authorize(
      tool: writeTool,
      sessionId: 's1',
      arguments: <String, Object?>{'path': 'a.txt', 'content': 'secret'},
    );

    // 用户确认的是"这次这些参数"，只给工具名等于让人盲签。
    expect(
      seen,
      equals(<String, Object?>{'path': 'a.txt', 'content': 'secret'}),
    );
    expect(seenTool, equals('fake_write_file'));
  });
}
