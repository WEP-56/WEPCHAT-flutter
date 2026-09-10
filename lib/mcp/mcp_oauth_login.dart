import 'package:http/http.dart' as http;
import 'package:mcp_dart/mcp_dart.dart' as sdk;

import '../core/cancellation_token.dart';
import '../platform/mcp_transports.dart';
import 'mcp_config.dart';
import 'mcp_connection.dart';
import 'mcp_error_text.dart';
import 'mcp_oauth.dart';
import 'mcp_oauth_provider.dart';
import 'mcp_oauth_redirect.dart';

/// 打开浏览器之前要展示给用户的授权信息。
///
/// 授权服务器可能与 MCP 服务器不同源，跳转前必须让用户看到具体域名和请求的
/// 权限范围，而不是替他决定——这也是规范对客户端的安全要求。
final class McpAuthorizationRequest {
  const McpAuthorizationRequest({
    required this.serverName,
    required this.authorizationUri,
    required this.redirectUri,
    required this.scope,
  });

  final String serverName;
  final Uri authorizationUri;

  /// 授权完成后浏览器要回跳的地址。
  ///
  /// 预注册客户端（GitHub、Atlassian 这类）要求提供方后台登记的地址与它完全
  /// 一致，所以必须展示给用户，不能只留在日志里。
  final Uri redirectUri;

  /// 授权请求里的 scope 原文；服务器未要求特定范围时为空。
  final String? scope;

  String get host => authorizationUri.host;
}

/// 等待用户完成浏览器授权的上限。
const Duration kMcpAuthorizationTimeout = Duration(minutes: 10);

/// 拿到 401 挑战与授权地址的上限。只覆盖网络往返，不包含用户操作时间。
const Duration kMcpAuthorizationTriggerTimeout = Duration(seconds: 60);

/// 走完一次 OAuth 授权码流程并把令牌写进存储。
///
/// 时序（与 MCP 授权章节一致）：
/// 1. 先在 `127.0.0.1` 上起回调监听；
/// 2. 驱动 transport 发出第一个请求，服务器返回 401；
/// 3. SDK 完成受保护资源元数据与授权服务器发现，构造出授权地址；
/// 4. [confirm] 让用户确认域名与 scope，确认后由 [openBrowser] 打开浏览器；
/// 5. 等回环回调带回 `code` 与 `state`，交换令牌并落盘。
///
/// 用户操作全部在超时窗口之外：授权地址一到手就结束等待，确认与浏览器交互不
/// 受任何计时器约束。
///
/// 这里刻意不走 `McpClient.connect`：它在失败时会关闭 transport，而
/// `finishAuthRedirect` 必须在同一个 transport 实例上完成。
Future<void> runMcpOAuthLogin({
  required McpServerConfig server,
  required McpRemoteEndpoint endpoint,
  required McpAuthStore store,
  required CancellationToken token,
  required Future<bool> Function(McpAuthorizationRequest request) confirm,
  required Future<void> Function(Uri authorizationUri) openBrowser,
  Duration timeout = kMcpAuthorizationTimeout,
  http.Client? httpClient,
}) async {
  final McpOAuthClient client = endpoint.oauthClient ?? McpOAuthClient();
  final McpOAuthRedirect redirect = await McpOAuthRedirect.start(
    port: client.callbackPort,
  );
  Uri? issuedUri;
  final sdk.Transport transport = buildRemoteTransport(
    endpoint,
    authProvider: McpOAuthProvider(
      tokens: McpTokenSource(
        serverId: server.id,
        client: client,
        store: store,
        httpClient: httpClient,
      ),
      redirectUri: redirect.redirectUri,
      // 只记录，不阻塞 SDK：用户确认放在超时窗口之外。
      onAuthorizationUri: (Uri uri) async => issuedUri = uri,
    ),
  );
  try {
    if (transport is! sdk.StreamableHttpClientTransport) {
      throw const McpFailure('OAuth 登录只支持 Streamable HTTP 传输');
    }
    final String? rejection = await _awaitAuthorizationChallenge(
      transport,
      token,
      redirectIssued: () => issuedUri != null,
    );
    final Uri? issued = issuedUri;
    if (issued == null) {
      throw McpFailure(
        '「${server.name}」没有要求 OAuth 授权'
        '${rejection == null ? '' : '（服务器返回：$rejection）'}。'
        '请确认该服务器的确使用 OAuth 登录；如果它用固定令牌或 PAT，'
        '请把认证方式改回「固定请求头」。',
      );
    }
    final String state = issued.queryParameters['state'] ?? '';
    if (state.isEmpty) {
      throw const McpFailure('授权地址缺少 state 参数，已中止本次授权');
    }
    token.throwIfCancelled();
        final bool approved = await confirm(
          McpAuthorizationRequest(
            serverName: server.name,
            authorizationUri: issued,
            redirectUri: redirect.redirectUri,
            scope: issued.queryParameters['scope'],
          ),
        );
    if (!approved) throw const McpFailure('已取消 OAuth 授权');
    await openBrowser(issued);

    final Map<String, String> callback = await redirect.wait(
      token,
      state: state,
      timeout: timeout,
    );
    final String? code = callback['code'];
    if (code == null || code.isEmpty) {
      throw const McpFailure('授权回调没有携带授权码');
    }
    await transport
        .finishAuthRedirect(code, state: state, issuer: callback['iss'])
        .timeout(kMcpAuthorizationTriggerTimeout);
  } on CancelledException {
    rethrow;
  } on McpFailure {
    rethrow;
  } on Object catch (error) {
    if (token.isCancelled) throw const CancelledException();
    throw McpFailure('「${server.name}」OAuth 登录失败：${mcpErrorText(error)}');
  } finally {
    try {
      await transport.close();
    } finally {
      await redirect.close();
    }
  }
}

const sdk.Implementation _clientInfo = sdk.Implementation(
  name: 'wepchat',
  version: '1',
);

/// 用探测请求触发 401 挑战。
///
/// 探测顺序固定为 `initialize`（≤2025-11-25 生命周期）→ `server/discover`
/// （2026-07-28 无状态模型）。顺序不能反过来：2025-11-25 的服务器不实现
/// `server/discover`，先发它只会多拿一个协议错误。
///
/// 两级探测是必须的。无状态服务器会先做协议校验再进认证中间件：拿 `initialize`
/// 去问它，得到的是"协议错误"而不是 401，而 SDK 会把这类响应体当作普通 JSON-RPC
/// 消息派发掉（`send` 正常返回）。只发一个请求就会看起来像"服务器不需要认证"。
/// 只有让请求在协议层面合法，认证层才有机会返回 401。
///
/// 非 401 的失败一律忽略并继续下一个探测：探测本身不是业务流程，能拿到 401
/// 就行。返回最后一次观察到的拒绝原因，用于在确实拿不到 401 时说明原因。
Future<String?> _awaitAuthorizationChallenge(
  sdk.StreamableHttpClientTransport transport,
  CancellationToken token, {
  required bool Function() redirectIssued,
}) async {
  token.throwIfCancelled();
  await transport.start();
  String? rejection;
  transport.onmessage = (sdk.JsonRpcMessage message) {
    if (message is sdk.JsonRpcError) {
      rejection ??= _describeProtocolError(message.error);
    }
  };
  for (final sdk.JsonRpcRequest probe in _authorizationProbes()) {
    token.throwIfCancelled();
    try {
      await transport.send(probe).timeout(kMcpAuthorizationTriggerTimeout);
    } on sdk.UnauthorizedError catch (error) {
      if (redirectIssued()) return null;
      // 服务器确实要认证（401 成立），但发现阶段没能走完。这不是"不需要
      // 认证"，必须如实上报，否则会被误导成服务器配置问题。
      throw McpFailure('授权流程在发现阶段中断：${_describeDiscoveryFailure(error)}');
    } on Object catch (error) {
      if (token.isCancelled) throw const CancelledException();
      rejection ??= mcpErrorText(error);
    }
  }
  return rejection;
}

/// 探测用的 id 用负数，避开 SDK 内部使用的请求编号。
List<sdk.JsonRpcRequest> _authorizationProbes() => <sdk.JsonRpcRequest>[
  sdk.JsonRpcRequest(
    id: -1,
    method: sdk.Method.initialize,
    params: sdk.InitializeRequest(
      protocolVersion: sdk.McpProtocol.legacy.preferredProtocolVersion,
      capabilities: const sdk.ClientCapabilities(),
      clientInfo: _clientInfo,
    ).toJson(),
  ),
  sdk.JsonRpcServerDiscoverRequest(
    id: -2,
    meta: sdk.buildProtocolRequestMeta(
      protocolVersion: sdk.McpProtocol.stable.preferredProtocolVersion,
      clientInfo: _clientInfo,
      clientCapabilities: const sdk.ClientCapabilities(),
    ),
  ),
];

/// 把发现阶段失败翻译成可操作的说明。
///
/// 授权服务器既没有 Client ID Metadata Document 也不支持动态注册时（GitHub
/// 的 `github.com/login/oauth`、Atlassian 都属于这类），SDK 只会报一句英文的
/// "No OAuth client registration is available"。用户看到这句话无法判断该做
/// 什么，所以这里补上唯一可行的出路：自建 OAuth 应用 + 预注册回调地址。
///
/// 判断依赖 SDK 的措辞。匹配不上就退回原文——只是少了这条提示，不会误报。
String _describeDiscoveryFailure(sdk.UnauthorizedError error) {
  final String reason = error.message ?? '服务器没有提供受保护资源元数据';
  if (!reason.toLowerCase().contains('client registration')) return reason;
  return '$reason。'
      '这个授权服务器不支持自动注册客户端，只能使用预注册客户端：\n'
      '1. 到提供方后台创建一个 OAuth 应用，拿到客户端 ID 与客户端密钥；\n'
      '2. 在服务器配置的「OAuth 登录」里填入这两项，并填一个固定的「回调端口」；\n'
      '3. 把配置里显示的回调地址原样登记为应用的授权回调地址；\n'
      '4. 保存后重新点「登录授权」。';
}

String _describeProtocolError(sdk.JsonRpcErrorData error) {
  final String message = error.message;
  return '协议错误 ${error.code}'
      '${message.isEmpty ? '' : '：${message.length > 80 ? '${message.substring(0, 80)}…' : message}'}';
}
