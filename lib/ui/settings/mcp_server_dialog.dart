import 'dart:convert';

import 'package:flutter/material.dart';

import '../../core/ulid.dart';
import '../../mcp/mcp_config.dart';
import '../../theme/palette.dart';
import '../../tools/tool_permission.dart';
import 'dialog_bits.dart';

Future<McpServerConfig?> showMcpServerDialog(
  BuildContext context, {
  required bool supportsStdio,
  McpServerConfig? existing,
}) => showDialog<McpServerConfig>(
  context: context,
  builder: (_) =>
      _McpServerDialog(supportsStdio: supportsStdio, existing: existing),
);

class _McpServerDialog extends StatefulWidget {
  const _McpServerDialog({required this.supportsStdio, this.existing});
  final bool supportsStdio;
  final McpServerConfig? existing;

  @override
  State<_McpServerDialog> createState() => _McpServerDialogState();
}

class _McpServerDialogState extends State<_McpServerDialog> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _url = TextEditingController();
  final TextEditingController _headers = TextEditingController(text: '{}');
  final TextEditingController _clientId = TextEditingController();
  final TextEditingController _clientSecret = TextEditingController();
  final TextEditingController _scopes = TextEditingController();
  final TextEditingController _callbackPort = TextEditingController();
  final TextEditingController _command = TextEditingController(text: 'npx');
  final TextEditingController _arguments = TextEditingController(text: '[]');
  final TextEditingController _environment = TextEditingController(text: '{}');
  final TextEditingController _directory = TextEditingController();
  final TextEditingController _timeout = TextEditingController(text: '60');
  McpTransportKind _kind = McpTransportKind.streamableHttp;
  McpRemoteAuth _auth = McpRemoteAuth.headers;
  String? _error;
  bool _hideSecrets = true;

  @override
  void initState() {
    super.initState();
    final McpServerConfig? server = widget.existing;
    if (server == null) return;
    _name.text = server.name;
    _kind = server.endpoint.kind;
    _timeout.text = '${server.timeout.inSeconds}';
    switch (server.endpoint) {
      case McpRemoteEndpoint(
        :final url,
        :final headers,
        :final auth,
        :final oauth,
      ):
        _url.text = url.toString();
        _headers.text = jsonEncode(headers);
        _auth = auth;
        if (oauth != null) {
          _clientId.text = oauth.clientId;
          _clientSecret.text = oauth.clientSecret ?? '';
          _scopes.text = oauth.scopes.join(' ');
          _callbackPort.text = oauth.callbackPort?.toString() ?? '';
        }
      case McpStdioEndpoint(
        :final command,
        :final arguments,
        :final environment,
        :final workingDirectory,
      ):
        _command.text = command;
        _arguments.text = jsonEncode(arguments);
        _environment.text = jsonEncode(environment);
        _directory.text = workingDirectory ?? '';
    }
  }

  @override
  void dispose() {
    for (final TextEditingController controller in <TextEditingController>[
      _name,
      _url,
      _headers,
      _clientId,
      _clientSecret,
      _scopes,
      _callbackPort,
      _command,
      _arguments,
      _environment,
      _directory,
      _timeout,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.existing == null ? '添加 MCP 服务器' : '编辑 MCP 服务器'),
      content: SizedBox(
        width: dialogWidth(context),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              LabeledField(label: '名称', controller: _name, autofocus: true),
              DropdownButtonFormField<McpTransportKind>(
                initialValue: _kind,
                decoration: const InputDecoration(
                  labelText: '连接方式',
                  isDense: true,
                ),
                isExpanded: true,
                items: <DropdownMenuItem<McpTransportKind>>[
                  for (final McpTransportKind kind in McpTransportKind.values)
                    if (kind != McpTransportKind.stdio ||
                        widget.supportsStdio ||
                        widget.existing?.endpoint.kind ==
                            McpTransportKind.stdio)
                      DropdownMenuItem<McpTransportKind>(
                        value: kind,
                        enabled:
                            kind != McpTransportKind.stdio ||
                            widget.supportsStdio,
                        child: Text(
                          kind.label,
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                ],
                onChanged: (McpTransportKind? kind) {
                  if (kind == null) return;
                  setState(() {
                    _kind = kind;
                    // SSE 传输没有 OAuth 入口，切过去就退回固定请求头。
                    if (kind == McpTransportKind.sse) {
                      _auth = McpRemoteAuth.headers;
                    }
                  });
                },
              ),
              const SizedBox(height: 16),
              if (_kind == McpTransportKind.stdio)
                ..._stdioFields()
              else
                ..._remoteFields(),
              LabeledField(
                label: '请求超时（秒）',
                controller: _timeout,
                numeric: true,
                helper: '1–600 秒；首次使用 npx/uvx 下载依赖可能需要更长时间。',
              ),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () => setState(() => _hideSecrets = !_hideSecrets),
                  icon: Icon(
                    _hideSecrets ? Icons.visibility : Icons.visibility_off,
                    size: 16,
                  ),
                  label: Text(_hideSecrets ? '显示密钥字段' : '隐藏密钥字段'),
                ),
              ),
              if (_error != null)
                Text(
                  _error!,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.error,
                    fontSize: 12,
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(onPressed: _save, child: const Text('保存')),
      ],
    );
  }

  List<Widget> _remoteFields() => <Widget>[
    LabeledField(
      label: '服务器地址',
      controller: _url,
      hint: _kind == McpTransportKind.sse
          ? 'https://example.com/sse'
          : 'https://example.com/mcp',
      helper: '填写完整接口地址。SSE 需要服务器提供旧版 HTTP + SSE 接口。',
      mono: true,
    ),
    if (!supportsOAuth)
      LabeledField(
        label: '请求头（JSON 对象）',
        controller: _headers,
        hint: '{"Authorization":"Bearer …"}',
        helper: '值必须是字符串；无请求头时填写 {}。旧式 SSE 只支持固定请求头，'
            '服务器要求 OAuth 登录时需要改用 Streamable HTTP。',
        obscure: _hideSecrets,
        mono: true,
      )
    else ...<Widget>[
      DropdownButtonFormField<McpRemoteAuth>(
        initialValue: _auth,
        decoration: const InputDecoration(labelText: '认证方式', isDense: true),
        isExpanded: true,
        items: <DropdownMenuItem<McpRemoteAuth>>[
          for (final McpRemoteAuth auth in McpRemoteAuth.values)
            DropdownMenuItem<McpRemoteAuth>(
              value: auth,
              child: Text(auth.label, style: const TextStyle(fontSize: 12)),
            ),
        ],
        onChanged: (McpRemoteAuth? auth) {
          if (auth != null) setState(() => _auth = auth);
        },
      ),
      const SizedBox(height: 14),
      if (_auth == McpRemoteAuth.headers)
        LabeledField(
          label: '请求头（JSON 对象）',
          controller: _headers,
          hint: '{"Authorization":"Bearer …"}',
          helper: '值必须是字符串；无请求头时填写 {}。需要交互登录的服务器请改选「OAuth 登录」。',
          obscure: _hideSecrets,
          mono: true,
        )
      else
        ..._oauthFields(),
    ],
  ];

  /// OAuth 只在 Streamable HTTP 上可用；SSE 连规范入口都没有。
  bool get supportsOAuth => _kind == McpTransportKind.streamableHttp;

  List<Widget> _oauthFields() => <Widget>[
    LabeledField(
      label: '客户端 ID',
      controller: _clientId,
      hint: '留空自动注册',
      helper: '留空时由服务器分配。提示「不支持自动注册客户端」时必须填写——'
          'GitHub、Atlassian 这类需要在提供方后台自建 OAuth 应用。',
      mono: true,
    ),
    LabeledField(
      label: '客户端密钥',
      controller: _clientSecret,
      helper: '只有机密客户端需要；GitHub 这类应用必须填。公开客户端留空。',
      obscure: _hideSecrets,
      mono: true,
    ),
    LabeledField(
      label: '权限范围（可选）',
      controller: _scopes,
      hint: 'tools:read tools:write',
      helper: '空格或逗号分隔。留空时使用服务器在 401 响应里要求的范围。',
      mono: true,
    ),
    LabeledField(
      label: '回调端口',
      controller: _callbackPort,
      numeric: true,
      helper: '留空使用系统分配的临时端口。提供方要求回调地址精确匹配时'
          '（GitHub 就是这样）必须填 1024–65535 的固定端口。',
    ),
    ValueListenableBuilder<TextEditingValue>(
      valueListenable: _callbackPort,
      builder: (BuildContext context, TextEditingValue value, Widget? child) {
        final int? port = int.tryParse(value.text.trim());
        return Text(
          port == null
              ? '回调地址：http://127.0.0.1:<临时端口>/callback（端口每次授权都不同，'
                    '授权弹窗里会显示实际地址）'
              : '回调地址：http://127.0.0.1:$port/callback —— 需要预注册客户端时，'
                    '把它原样登记为提供方后台的授权回调地址',
          style: port == null
              ? TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: context.palette.text3,
                )
              : TextStyle(
                  fontSize: 11.5,
                  height: 1.5,
                  color: context.palette.text2,
                ),
        );
      },
    ),
    const SizedBox(height: 10),
    Text(
      'OAuth 登录在「设置 → 高级功能」的服务器卡片上发起；令牌保存在本机，'
      '可在同一位置退出登录。',
      style: TextStyle(
        fontSize: 11.5,
        height: 1.5,
        color: context.palette.text3,
      ),
    ),
  ];

  List<Widget> _stdioFields() => <Widget>[
    if (!widget.supportsStdio)
      Text(
        '此设备不支持 stdio，请改用网络连接方式。',
        style: TextStyle(color: context.palette.text2),
      ),
    LabeledField(
      label: '可执行文件',
      controller: _command,
      hint: 'npx / uvx / node 或可执行文件的绝对路径',
      helper: '只填写程序名，参数填在下方。Node.js 或 uv 需要自行安装。',
      mono: true,
    ),
    TextField(
      controller: _arguments,
      minLines: 2,
      maxLines: 5,
      style: const TextStyle(fontSize: 12),
      decoration: const InputDecoration(
        labelText: '参数（JSON 字符串数组）',
        hintText:
            '["-y", "@modelcontextprotocol/server-filesystem", "D:\\\\Documents"]',
        helperText: '每个参数单独一个字符串；无参数时填写 []。',
        helperMaxLines: 3,
        border: OutlineInputBorder(),
        isDense: true,
      ),
    ),
    const SizedBox(height: 14),
    LabeledField(
      label: '环境变量（JSON 对象）',
      controller: _environment,
      hint: '{"API_KEY":"…"}',
      helper: '无自定义环境变量时填写 {}。只继承运行程序所需的系统变量。',
      obscure: _hideSecrets,
      mono: true,
    ),
    LabeledField(
      label: '工作目录（可选）',
      controller: _directory,
      helper: '留空使用当前会话工作区。这个目录不会限制服务器访问其他位置。',
      mono: true,
    ),
  ];

  void _save() {
    try {
      if (_kind == McpTransportKind.stdio && !widget.supportsStdio) {
        throw const FormatException('Android 不支持 stdio，请选择网络连接方式');
      }
      final int? seconds = int.tryParse(_timeout.text.trim());
      if (seconds == null) throw const FormatException('超时必须是 1–600 的整数秒');
      final String portText = _callbackPort.text.trim();
      final int? callbackPort = portText.isEmpty ? null : int.tryParse(portText);
      if (portText.isNotEmpty && callbackPort == null) {
        throw const FormatException('回调端口必须是 1024–65535 的整数');
      }
      final bool usesOAuth = supportsOAuth && _auth == McpRemoteAuth.oauth;
      final Map<String, Object?> json = <String, Object?>{
        'id': widget.existing?.id ?? Ulid.generate(),
        'name': _name.text.trim(),
        'transport': _kind.name,
        'enabled': widget.existing?.enabled ?? true,
        'permission': (widget.existing?.permission ?? ToolPermission.ask).name,
        'timeoutSeconds': seconds,
        if (_kind == McpTransportKind.stdio) ...<String, Object?>{
          'command': _command.text.trim(),
          'arguments': _jsonField(_arguments, '参数'),
          'environment': _jsonField(_environment, '环境变量'),
          if (_directory.text.trim().isNotEmpty)
            'workingDirectory': _directory.text.trim(),
        } else ...<String, Object?>{
          'url': _url.text.trim(),
          // SSE 没有 OAuth 入口，配置里不允许出现这个组合。
          'auth': usesOAuth ? _auth.name : McpRemoteAuth.headers.name,
          'headers': usesOAuth
              ? const <String, Object?>{}
              : _jsonField(_headers, '请求头'),
          if (usesOAuth)
            'oauth': <String, Object?>{
              'clientId': _clientId.text.trim(),
              if (_clientSecret.text.trim().isNotEmpty)
                'clientSecret': _clientSecret.text.trim(),
              'scopes': _scopeList(),
              'callbackPort': ?callbackPort,
            },
        },
      };
      Navigator.of(context).pop(McpServerConfig.fromJson(json));
    } on FormatException catch (error) {
      setState(() => _error = error.message);
    }
  }

  List<String> _scopeList() => _scopes.text
      .split(RegExp(r'[\s,]+'))
      .where((String scope) => scope.isNotEmpty)
      .toList();

  Object? _jsonField(TextEditingController controller, String label) {
    try {
      return jsonDecode(controller.text);
    } on FormatException {
      throw FormatException('$label 的 JSON 格式不正确');
    }
  }
}
