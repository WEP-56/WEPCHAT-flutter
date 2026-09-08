import 'dart:async';

import 'package:flutter/material.dart';

import '../../../core/cancellation_token.dart';
import '../../../mcp/mcp_config.dart';
import '../../../mcp/mcp_connection.dart';
import '../../../state/app_scope.dart';
import '../../../state/app_settings.dart';
import '../../../state/mcp_controller.dart';
import '../../../theme/palette.dart';
import '../../../tools/tool_permission.dart';
import '../../widgets/segmented_control.dart';
import '../../widgets/toast.dart';
import '../mcp_server_dialog.dart';
import '../settings_card.dart';

class AdvancedSection extends StatefulWidget {
  const AdvancedSection({super.key});

  @override
  State<AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<AdvancedSection> {
  final Map<String, CancellationTokenSource> _tests =
      <String, CancellationTokenSource>{};
  bool _confirming = false;

  @override
  void dispose() {
    for (final CancellationTokenSource source in _tests.values) {
      source.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final AppSettings settings = context.settings;
    final McpController mcp = context.sessions.mcp;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[settings, mcp]),
      builder: (BuildContext context, Widget? child) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SettingsCard(
            title: 'MCP',
            subtitle: '连接外部服务器，为助手添加工具。',
            children: <Widget>[
              SettingsRow(
                title: '启用 MCP',
                desc: '默认关闭。开启前请确认外部工具的访问边界。',
                trailing: Switch(
                  value: settings.mcp.enabled,
                  onChanged: _confirming
                      ? null
                      : (bool value) => unawaited(_setEnabled(value)),
                ),
              ),
              if (settings.mcp.enabled)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    kMcpBoundaryNotice,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.6,
                      color: context.palette.text2,
                    ),
                  ),
                ),
              Text(
                mcp.supportsStdio
                    ? '本机支持 Streamable HTTP、SSE 和 stdio 本地服务器。'
                    : '本机支持 Streamable HTTP 和 SSE 网络服务器。stdio 仅 Windows 可用。',
                style: TextStyle(fontSize: 11.5, color: context.palette.text3),
              ),
              const SizedBox(height: 8),
              Text(
                '聊天时按轮次连接，结束后关闭。配置变更会取消现有 MCP 连接，下一轮使用新配置。'
                '支持工具的文本、结构化结果与文本资源；二进制图片和音频暂不能展示。',
                style: TextStyle(
                  fontSize: 11,
                  height: 1.5,
                  color: context.palette.text3,
                ),
              ),
              if (settings.lastWriteError != null)
                TextButton(
                  onPressed: () => unawaited(settings.flush()),
                  child: const Text('设置保存失败，点击重试'),
                ),
              if (mcp.cleanupError != null)
                Text(
                  mcp.cleanupError!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  '服务器（${settings.mcp.servers.length}）',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
              FilledButton.tonalIcon(
                onPressed: settings.mcp.servers.length >= kMcpMaxServers
                    ? null
                    : () => unawaited(_edit()),
                icon: const Icon(Icons.add, size: 16),
                label: const Text('添加服务器'),
              ),
            ],
          ),
          if (settings.mcp.servers.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Text(
                '尚未添加 MCP 服务器。可以先完成配置，再启用 MCP。',
                style: TextStyle(fontSize: 12),
              ),
            ),
          for (final McpServerConfig server in settings.mcp.servers)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _serverCard(server, settings, mcp),
            ),
        ],
      ),
    );
  }

  Widget _serverCard(
    McpServerConfig server,
    AppSettings settings,
    McpController mcp,
  ) {
    final bool supported =
        server.endpoint.kind != McpTransportKind.stdio || mcp.supportsStdio;
    final McpProbeState? probe = mcp.probe(server.id);
    return SettingsCard(
      title: server.name,
      subtitle: '${server.endpoint.kind.label}${supported ? '' : ' · 当前设备不支持'}',
      children: <Widget>[
        SettingsRow(
          title: '使用此服务器',
          trailing: Switch(
            value: server.enabled,
            onChanged: supported || server.enabled
                ? (bool value) =>
                      settings.saveMcpServer(server.copyWith(enabled: value))
                : null,
          ),
        ),
        SettingsRow(
          title: '工具调用权限',
          desc: '应用于此服务器的全部工具。',
          trailing: SegmentedControl<ToolPermission>(
            small: true,
            value: server.permission,
            options: ToolPermission.values
                .map(
                  (ToolPermission value) =>
                      SegOption<ToolPermission>(value, value.label),
                )
                .toList(),
            onChanged: (ToolPermission value) =>
                settings.saveMcpServer(server.copyWith(permission: value)),
          ),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: <Widget>[
            OutlinedButton(
              onPressed: settings.mcp.enabled && supported
                  ? () => unawaited(_test(server))
                  : null,
              child: Text(_tests.containsKey(server.id) ? '取消测试' : '测试连接'),
            ),
            TextButton(
              onPressed: () => unawaited(_edit(server)),
              child: const Text('编辑'),
            ),
            TextButton(
              onPressed: () => unawaited(_remove(server)),
              child: const Text('删除'),
            ),
          ],
        ),
        if (server.endpoint.kind == McpTransportKind.stdio)
          const Text(
            '测试连接和聊天会启动本地进程；npx/uvx 可能下载依赖。',
            style: TextStyle(fontSize: 11),
          ),
        if (probe is McpChecking)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text('正在连接并发现工具…'),
          ),
        if (probe is McpProbeFailed)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: SelectableText(
              probe.message,
              style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.error,
              ),
            ),
          ),
        if (probe is McpDiscovered)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              '已发现 ${probe.tools.length} 个工具',
              style: const TextStyle(fontSize: 12),
            ),
            children: <Widget>[
              Align(
                alignment: Alignment.centerLeft,
                child: SelectableText(
                  probe.tools.join('\n'),
                  style: const TextStyle(fontSize: 11.5),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Future<void> _setEnabled(bool enabled) async {
    if (!enabled) {
      context.settings.setMcpEnabled(false);
      return;
    }
    setState(() => _confirming = true);
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('启用 MCP'),
        content: const SingleChildScrollView(child: Text(kMcpBoundaryNotice)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('了解并启用'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    setState(() => _confirming = false);
    if (confirmed == true) context.settings.setMcpEnabled(true);
  }

  Future<void> _edit([McpServerConfig? server]) async {
    final McpServerConfig? saved = await showMcpServerDialog(
      context,
      supportsStdio: context.sessions.mcp.supportsStdio,
      existing: server,
    );
    if (saved == null || !mounted) return;
    try {
      context.settings.saveMcpServer(saved);
    } on FormatException catch (error) {
      showAppToast(context, error.message);
    }
  }

  Future<void> _remove(McpServerConfig server) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('删除 MCP 服务器'),
        content: Text('删除「${server.name}」的连接配置？'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      context.settings.removeMcpServer(server.id);
    }
  }

  Future<void> _test(McpServerConfig server) async {
    final CancellationTokenSource? running = _tests[server.id];
    if (running != null) {
      running.cancel();
      return;
    }
    final CancellationTokenSource source = CancellationTokenSource();
    setState(() => _tests[server.id] = source);
    try {
      await context.sessions.mcp.testServer(
        server.id,
        source.token,
        workspaceRoot: context.sessions.workspacePathFor(
          context.sessions.activeId,
        ),
      );
    } on McpFailure catch (error) {
      if (mounted) showAppToast(context, error.message);
    } finally {
      _tests.remove(server.id);
      if (mounted) setState(() {});
    }
  }
}
