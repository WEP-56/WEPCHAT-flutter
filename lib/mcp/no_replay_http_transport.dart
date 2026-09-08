import 'package:mcp_dart/mcp_dart.dart' as sdk;

/// The SDK refreshes stale sessions and replays their requests. A tool call
/// may already have changed external state, so WePChat requires a new turn
/// instead of permitting that automatic replay.
final class McpSessionExpired extends Error {}

class NoReplayHttpTransport extends sdk.StreamableHttpClientTransport {
  NoReplayHttpTransport(super.url, {super.opts});

  @override
  Future<void> send(
    sdk.JsonRpcMessage message, {
    int? relatedRequestId,
    String? resumptionToken,
    void Function(String)? onResumptionToken,
  }) async {
    try {
      await super.send(
        message,
        relatedRequestId: relatedRequestId,
        resumptionToken: resumptionToken,
        onResumptionToken: onResumptionToken,
      );
    } on sdk.StaleSessionError {
      throw McpSessionExpired();
    }
  }
}
