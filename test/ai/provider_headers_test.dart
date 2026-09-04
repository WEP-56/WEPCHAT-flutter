import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/ai/provider_config.dart';
import 'package:wepchat/ai/provider_headers.dart';

void main() {
  test('自定义 Header 覆盖默认值且名称大小写不敏感', () {
    final Map<String, String> headers = buildProviderHeaders(
      defaults: const <String, String>{
        'authorization': 'Bearer default',
        'content-type': 'application/json',
      },
      custom: const <String, String>{
        'Authorization': 'Basic custom',
        'X-Gateway': 'relay',
      },
    );

    expect(headers['Authorization'], 'Basic custom');
    expect(headers.containsKey('authorization'), isFalse);
    expect(headers['X-Gateway'], 'relay');
    expect(headers['content-type'], 'application/json');
  });

  test('传输层 Header 不会进入请求', () {
    final Map<String, String> headers = buildProviderHeaders(
      defaults: const <String, String>{},
      custom: const <String, String>{
        'Host': 'evil.example',
        'Content-Length': '1',
        'X-Ok': 'yes',
      },
    );

    expect(headers, const <String, String>{'X-Ok': 'yes'});
  });

  test('ProviderConfig 往返保存自定义 Header', () {
    const ProviderConfig original = ProviderConfig(
      id: 'relay',
      displayName: 'Relay',
      apiKind: ApiKind.openaiCompletions,
      baseUrl: 'https://example.test/v1',
      apiKey: 'secret',
      customHeaders: <String, String>{
        'User-Agent': 'opencode/1.0.0',
        'originator': 'opencode',
      },
    );

    final ProviderConfig? restored = ProviderConfig.fromJson(original.toJson());
    expect(restored, isNotNull);
    expect(restored!.customHeaders, original.customHeaders);
  });

  test('三个客户端预设提供核心标识', () {
    expect(
      providerHeaderPreset('opencode', '1.2.3'),
      containsPair('originator', 'opencode'),
    );
    expect(
      providerHeaderPreset('codex', '0.105.0')['User-Agent'],
      startsWith('codex_cli_rs/0.105.0'),
    );
    expect(
      providerHeaderPreset('claudeCode', '2.1.260'),
      containsPair('x-app', 'cli'),
    );
  });
}
