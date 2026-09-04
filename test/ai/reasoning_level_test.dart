import 'package:flutter_test/flutter_test.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/model_compat.dart';
import 'package:wepchat/ai/openai/openai_request.dart';
import 'package:wepchat/ai/openai/responses_request.dart';
import 'package:wepchat/ai/provider_api.dart';

const ModelSpec _model = ModelSpec(
  id: 'reasoning-model',
  providerId: 'openai',
  compat: ModelCompat(thinking: ThinkingFormat.openaiReasoningEffort),
);

ProviderRequest _request(int budget) => ProviderRequest(
  model: _model,
  messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
  thinkingBudget: budget,
);

void main() {
  test('Chat Completions 支持 low 到 max 五档', () {
    expect(buildCompletionsRequest(_request(4096))['reasoning_effort'], 'low');
    expect(
      buildCompletionsRequest(_request(10000))['reasoning_effort'],
      'medium',
    );
    expect(
      buildCompletionsRequest(_request(20000))['reasoning_effort'],
      'high',
    );
    expect(
      buildCompletionsRequest(_request(40000))['reasoning_effort'],
      'xhigh',
    );
    expect(buildCompletionsRequest(_request(80000))['reasoning_effort'], 'max');
  });

  test('Responses API 支持 low 到 max 五档', () {
    String effort(int budget) {
      final Map<String, Object?> body = buildResponsesRequest(_request(budget));
      return (body['reasoning']! as Map<String, Object?>)['effort']! as String;
    }

    expect(effort(4096), 'low');
    expect(effort(10000), 'medium');
    expect(effort(20000), 'high');
    expect(effort(40000), 'xhigh');
    expect(effort(80000), 'max');

    final Map<String, Object?> reasoning =
        buildResponsesRequest(_request(20000))['reasoning']!
            as Map<String, Object?>;
    expect(reasoning['summary'], 'auto');
  });
}
