import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/provider_api.dart';
import 'package:wepchat/core/cancellation_token.dart';
import 'package:wepchat/core/errors.dart';
import 'package:wepchat/tools/echo_tool.dart';
import 'package:wepchat/tools/tool.dart';
import 'package:wepchat/tools/tool_registry.dart';

/// 抛异常的工具，验证 dispatch 不让异常逃出去。
class _ThrowingTool extends Tool {
  const _ThrowingTool();

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'boom',
        description: '总是抛异常',
        schema: <String, Object?>{'type': 'object'},
      );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    throw StateError('故意炸');
  }
}

/// 中断感知的工具，验证 CancelledException 被转成结果。
class _CancellingTool extends Tool {
  const _CancellingTool();

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'slow',
        description: '检查中断',
        schema: <String, Object?>{'type': 'object'},
      );

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async {
    context.token.throwIfCancelled();
    return ToolResult.ok('没被中断');
  }
}

/// 写类工具，验证 requiresApproval 由工具自己声明。
class _WritingTool extends Tool {
  const _WritingTool();

  @override
  ToolDefinition get definition => const ToolDefinition(
        name: 'write',
        description: '写文件',
        schema: <String, Object?>{'type': 'object'},
      );

  @override
  bool get requiresApproval => true;

  @override
  Future<ToolResult> execute(
    Map<String, Object?> arguments,
    ToolContext context,
  ) async =>
      ToolResult.ok('written');
}

void main() {
  ToolContext contextWith(CancellationToken token) => ToolContext(
        sessionId: 'session-1',
        workspaceRoot: '/tmp/ws',
        token: token,
      );

  final ToolContext liveContext = contextWith(CancellationToken.none);

  group('声明排序', () {
    test('declarations 按名字典序，与注册顺序无关', () {
      // 倒序注册，输出仍应是 echo < slow < write。
      final ToolRegistry registry = ToolRegistry(const <Tool>[
        _WritingTool(),
        _CancellingTool(),
        EchoTool(),
      ]);

      expect(
        registry.declarations.map((ToolDefinition d) => d.name).toList(),
        equals(<String>['echo', 'slow', 'write']),
      );
    });

    test('注册顺序不同但声明字节相同——缓存前缀才稳定', () {
      final ToolRegistry a = ToolRegistry(const <Tool>[
        EchoTool(),
        _WritingTool(),
      ]);
      final ToolRegistry b = ToolRegistry(const <Tool>[
        _WritingTool(),
        EchoTool(),
      ]);

      expect(
        a.declarations.map((ToolDefinition d) => d.name).toList(),
        equals(b.declarations.map((ToolDefinition d) => d.name).toList()),
      );
    });

    test('空注册表没有声明', () {
      expect(ToolRegistry.empty.declarations, isEmpty);
    });

    test('重名工具在构造时就报错，不等到调用', () {
      expect(
        () => ToolRegistry(const <Tool>[EchoTool(), EchoTool()]),
        throwsA(isA<StorageError>()),
      );
    });
  });

  group('查找', () {
    final ToolRegistry registry = ToolRegistry(const <Tool>[EchoTool()]);

    test('contains 与 find 一致', () {
      expect(registry.contains('echo'), isTrue);
      expect(registry.find('echo'), isNotNull);
      expect(registry.contains('nope'), isFalse);
      expect(registry.find('nope'), isNull);
    });

    test('requiresApproval 默认 false，写类工具自己声明 true', () {
      expect(const EchoTool().requiresApproval, isFalse);
      expect(const _WritingTool().requiresApproval, isTrue);
    });
  });

  group('dispatch', () {
    test('正常执行返回结果', () async {
      final ToolRegistry registry = ToolRegistry(const <Tool>[EchoTool()]);

      final ToolResult result = await registry.dispatch(
        'echo',
        <String, Object?>{'message': 'hi'},
        liveContext,
      );

      expect(result.isError, isFalse);
      expect(result.content, equals('Echo: hi'));
    });

    test('参数类型不对时工具自己返回 error，不抛', () async {
      final ToolRegistry registry = ToolRegistry(const <Tool>[EchoTool()]);

      final ToolResult result = await registry.dispatch(
        'echo',
        <String, Object?>{'message': 42},
        liveContext,
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('message'));
    });

    test('未知工具名返回 error 并列出可用工具', () async {
      final ToolRegistry registry = ToolRegistry(const <Tool>[
        EchoTool(),
        _WritingTool(),
      ]);

      final ToolResult result = await registry.dispatch(
        'echoo',
        <String, Object?>{},
        liveContext,
      );

      expect(result.isError, isTrue);
      // 模型要能据此改用对的工具，所以候选名必须出现在文案里。
      expect(result.content, contains('echo'));
      expect(result.content, contains('write'));
    });

    test('工具内部抛异常被收成 error，不逃出 dispatch', () async {
      final ToolRegistry registry = ToolRegistry(const <Tool>[_ThrowingTool()]);

      final ToolResult result = await registry.dispatch(
        'boom',
        <String, Object?>{},
        liveContext,
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('boom'));
    });

    test('已取消的 token 直接返回中断结果，不执行工具', () async {
      final CancellationTokenSource source = CancellationTokenSource();
      source.cancel();

      final ToolRegistry registry = ToolRegistry(const <Tool>[EchoTool()]);
      final ToolResult result = await registry.dispatch(
        'echo',
        <String, Object?>{'message': 'hi'},
        contextWith(source.token),
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('中断'));
    });

    test('工具执行中途抛 CancelledException 也转成结果', () async {
      final CancellationTokenSource source = CancellationTokenSource();
      final ToolRegistry registry = ToolRegistry(const <Tool>[
        _CancellingTool(),
      ]);

      // 先构造 context 再取消：绕过 dispatch 入口的预检查，
      // 走 throwIfCancelled 那条路。
      final ToolContext ctx = contextWith(source.token);
      source.cancel();

      final ToolResult result = await registry.dispatch(
        'slow',
        <String, Object?>{},
        ctx,
      );

      expect(result.isError, isTrue);
      expect(result.content, contains('中断'));
    });
  });
}
