import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:wepchat/ai/anthropic/anthropic_request.dart';
import 'package:wepchat/ai/messages.dart';
import 'package:wepchat/ai/model_catalog.dart';
import 'package:wepchat/ai/model_compat.dart';
import 'package:wepchat/ai/provider_api.dart';

/// 带缓存与思考的 anthropic 模型。
const ModelSpec _sonnet = ModelSpec(
  id: 'claude-sonnet-4-5',
  displayName: 'Claude Sonnet 4.5',
  providerId: 'anthropic',
  contextWindow: 200000,
  maxOutputTokens: 64000,
  compat: ModelCompat(
    thinking: ThinkingFormat.anthropicThinking,
    cache: CacheControlFormat.anthropic,
    visionInput: true,
  ),
);

/// 不带缓存的模型，用于验证开关真的生效。
const ModelSpec _noCache = ModelSpec(
  id: 'claude-plain',
  displayName: 'Plain',
  providerId: 'anthropic',
  contextWindow: 100000,
  maxOutputTokens: 8000,
);

void main() {
  group('请求体结构', () {
    test('必填字段', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
        ),
      );

      expect(body['model'], equals('claude-sonnet-4-5'));
      expect(body['max_tokens'], equals(64000));
      expect(body['stream'], isTrue);
      expect(body['messages'], isA<List<Object?>>());
    });

    test('system 走顶层字段而不是消息', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          systemPrompt: '你是助手',
          messages: <ChatMessageModel>[
            ChatMessageModel.system('这条应该被过滤'),
            ChatMessageModel.user('Hi'),
          ],
        ),
      );

      final List<Object?> system = body['system'] as List<Object?>;
      expect(system.length, equals(1));
      expect((system[0] as Map<String, Object?>)['text'], equals('你是助手'));

      // 消息列表里不该有 system
      final List<Object?> messages = body['messages'] as List<Object?>;
      expect(messages.length, equals(1));
      expect((messages[0] as Map<String, Object?>)['role'], equals('user'));
    });

    test('工具定义按传入顺序输出', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
          tools: const <ToolDefinition>[
            ToolDefinition(
              name: 'aaa',
              description: 'first',
              schema: <String, Object?>{'type': 'object'},
            ),
            ToolDefinition(
              name: 'bbb',
              description: 'second',
              schema: <String, Object?>{'type': 'object'},
            ),
          ],
        ),
      );

      final List<Object?> tools = body['tools'] as List<Object?>;
      expect(tools.length, equals(2));
      expect((tools[0] as Map<String, Object?>)['name'], equals('aaa'));
      expect((tools[1] as Map<String, Object?>)['name'], equals('bbb'));
    });

    test('thinking 开启时省略 temperature', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
          thinkingBudget: 10000,
          temperature: 0.7,
        ),
      );

      expect(body['thinking'], isNotNull);
      expect(
        (body['thinking']! as Map<String, Object?>)['budget_tokens'],
        equals(10000),
      );
      // anthropic 要求开 thinking 时 temperature 必须为 1，所以干脆不发
      expect(body.containsKey('temperature'), isFalse);
    });

    test('不支持 temperature 的模型不发这个字段', () {
      const ModelSpec noTemp = ModelSpec(
        id: 'x',
        displayName: 'X',
        providerId: 'anthropic',
        contextWindow: 1000,
        maxOutputTokens: 100,
        compat: ModelCompat(supportsTemperature: false),
      );

      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: noTemp,
          messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
          temperature: 0.7,
        ),
      );

      expect(body.containsKey('temperature'), isFalse);
    });
  });

  group('cache_control 落点', () {
    test('落点不超过四个', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          systemPrompt: '系统',
          messages: <ChatMessageModel>[
            ChatMessageModel.user('第一轮'),
            const ChatMessageModel(
              role: MessageRole.assistant,
              parts: <ContentPart>[TextPart('回答')],
              stopReason: StopReason.stop,
            ),
            ChatMessageModel.user('第二轮'),
          ],
          tools: const <ToolDefinition>[
            ToolDefinition(
              name: 't',
              description: 'd',
              schema: <String, Object?>{'type': 'object'},
            ),
          ],
        ),
      );

      final int count = _countCacheControl(body);
      expect(count, lessThanOrEqualTo(4));
      // system + tools + 最后一条 user = 3
      expect(count, equals(3));
    });

    test('落点只挂最后一条 user 消息', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[
            ChatMessageModel.user('第一轮'),
            const ChatMessageModel(
              role: MessageRole.assistant,
              parts: <ContentPart>[TextPart('回答')],
              stopReason: StopReason.stop,
            ),
            ChatMessageModel.user('第二轮'),
          ],
        ),
      );

      final List<Object?> messages = body['messages'] as List<Object?>;
      // 第一条 user 不挂
      expect(_hasCacheControl(messages[0]), isFalse);
      // assistant 不挂
      expect(_hasCacheControl(messages[1]), isFalse);
      // 最后一条 user 挂
      expect(_hasCacheControl(messages[2]), isTrue);
    });

    test('不支持缓存的模型不出现 cache_control', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _noCache,
          systemPrompt: '系统',
          messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
          tools: const <ToolDefinition>[
            ToolDefinition(
              name: 't',
              description: 'd',
              schema: <String, Object?>{'type': 'object'},
            ),
          ],
        ),
      );

      expect(_countCacheControl(body), equals(0));
    });
  });

  group('内容块映射', () {
    test('thinking 块带 signature 才回传', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[
            const ChatMessageModel(
              role: MessageRole.assistant,
              parts: <ContentPart>[
                ThinkingPart('有签名', signature: 'sig-abc'),
                ThinkingPart('无签名'),
                TextPart('正文'),
              ],
              stopReason: StopReason.stop,
            ),
            ChatMessageModel.user('继续'),
          ],
        ),
      );

      final List<Object?> messages = body['messages'] as List<Object?>;
      final List<Object?> blocks =
          (messages[0] as Map<String, Object?>)['content'] as List<Object?>;

      // 有签名的 thinking + 正文 = 2 个块，无签名的被丢掉
      expect(blocks.length, equals(2));
      expect((blocks[0] as Map<String, Object?>)['type'], equals('thinking'));
      expect(
        (blocks[0] as Map<String, Object?>)['signature'],
        equals('sig-abc'),
      );
      expect((blocks[1] as Map<String, Object?>)['type'], equals('text'));
    });

    test('tool_use 与 tool_result', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[
            const ChatMessageModel(
              role: MessageRole.assistant,
              parts: <ContentPart>[
                ToolCallPart(
                  id: 'call_1',
                  name: 'read_file',
                  arguments: <String, Object?>{'path': 'a.txt'},
                ),
              ],
              stopReason: StopReason.toolUse,
            ),
            const ChatMessageModel(
              role: MessageRole.tool,
              parts: <ContentPart>[
                ToolResultPart(
                  callId: 'call_1',
                  name: 'read_file',
                  content: 'file contents',
                ),
              ],
            ),
          ],
        ),
      );

      final List<Object?> messages = body['messages'] as List<Object?>;

      final Map<String, Object?> useBlock =
          ((messages[0] as Map<String, Object?>)['content']
              as List<Object?>)[0] as Map<String, Object?>;
      expect(useBlock['type'], equals('tool_use'));
      expect(useBlock['id'], equals('call_1'));
      expect(useBlock['input'], equals(<String, Object?>{'path': 'a.txt'}));

      // tool 角色映射成 user，结果是 user 消息里的 block（§4-9）
      final Map<String, Object?> resultMsg =
          messages[1] as Map<String, Object?>;
      expect(resultMsg['role'], equals('user'));
      final Map<String, Object?> resultBlock =
          (resultMsg['content'] as List<Object?>)[0] as Map<String, Object?>;
      expect(resultBlock['type'], equals('tool_result'));
      expect(resultBlock['tool_use_id'], equals('call_1'));
    });

    test('is_error 只在失败时出现', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[
            const ChatMessageModel(
              role: MessageRole.tool,
              parts: <ContentPart>[
                ToolResultPart(
                  callId: 'c1',
                  name: 't',
                  content: 'ok',
                ),
                ToolResultPart(
                  callId: 'c2',
                  name: 't',
                  content: 'failed',
                  isError: true,
                ),
              ],
            ),
          ],
        ),
      );

      final List<Object?> blocks =
          ((body['messages'] as List<Object?>)[0] as Map<String, Object?>)['content']
              as List<Object?>;

      expect((blocks[0] as Map<String, Object?>).containsKey('is_error'), isFalse);
      expect((blocks[1] as Map<String, Object?>)['is_error'], isTrue);
    });

    test('图片块', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[
            const ChatMessageModel(
              role: MessageRole.user,
              parts: <ContentPart>[
                ImagePart(base64Data: 'AAAA', mimeType: 'image/png'),
                TextPart('这是什么'),
              ],
            ),
          ],
        ),
      );

      final List<Object?> blocks =
          ((body['messages'] as List<Object?>)[0] as Map<String, Object?>)['content']
              as List<Object?>;

      expect((blocks[0] as Map<String, Object?>)['type'], equals('image'));
      final Map<String, Object?> source =
          (blocks[0] as Map<String, Object?>)['source'] as Map<String, Object?>;
      expect(source['media_type'], equals('image/png'));
      expect(source['data'], equals('AAAA'));
    });

    test('空文本块被跳过', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          messages: <ChatMessageModel>[
            const ChatMessageModel(
              role: MessageRole.user,
              parts: <ContentPart>[TextPart(''), TextPart('real')],
            ),
          ],
        ),
      );

      final List<Object?> blocks =
          ((body['messages'] as List<Object?>)[0] as Map<String, Object?>)['content']
              as List<Object?>;

      expect(blocks.length, equals(1));
      expect((blocks[0] as Map<String, Object?>)['text'], equals('real'));
    });
  });

  group('字节稳定性（§6-8）', () {
    /// 同一状态序列化两次，字节必须完全相等。
    ///
    /// 这是唯一能防住 prompt cache 回归的手段：Map 是插入序，改动构造顺序
    /// 不会报错、不会有任何症状，只会让所有用户的缓存静默失效。
    test('同一状态序列化两次字节相等', () {
      final ProviderRequest req = ProviderRequest(
        model: _sonnet,
        systemPrompt: '你是一个助手',
        messages: <ChatMessageModel>[
          ChatMessageModel.user('第一个问题'),
          const ChatMessageModel(
            role: MessageRole.assistant,
            parts: <ContentPart>[
              ThinkingPart('思考中', signature: 'sig1'),
              TextPart('回答'),
              ToolCallPart(
                id: 'c1',
                name: 'tool',
                arguments: <String, Object?>{'a': 1, 'b': 'two'},
              ),
            ],
            stopReason: StopReason.toolUse,
          ),
          const ChatMessageModel(
            role: MessageRole.tool,
            parts: <ContentPart>[
              ToolResultPart(callId: 'c1', name: 'tool', content: '结果'),
            ],
          ),
          ChatMessageModel.user('第二个问题'),
        ],
        tools: const <ToolDefinition>[
          ToolDefinition(
            name: 'tool',
            description: '一个工具',
            schema: <String, Object?>{
              'type': 'object',
              'properties': <String, Object?>{
                'a': <String, Object?>{'type': 'integer'},
                'b': <String, Object?>{'type': 'string'},
              },
              'required': <String>['a'],
            },
          ),
        ],
        thinkingBudget: 8000,
        sessionId: 'session-abc',
      );

      final String first = jsonEncode(buildAnthropicRequest(req));
      final String second = jsonEncode(buildAnthropicRequest(req));

      expect(first, equals(second));
    });

    test('字段顺序固定：model 在 max_tokens 之前', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _sonnet,
          systemPrompt: 'sys',
          messages: <ChatMessageModel>[ChatMessageModel.user('Hi')],
          tools: const <ToolDefinition>[
            ToolDefinition(
              name: 't',
              description: 'd',
              schema: <String, Object?>{'type': 'object'},
            ),
          ],
          thinkingBudget: 1000,
        ),
      );

      // 顺序即字节顺序，锁死它
      expect(
        body.keys.toList(),
        equals(<String>[
          'model',
          'max_tokens',
          'system',
          'tools',
          'thinking',
          'messages',
          'stream',
        ]),
      );
    });

    test('黄金样本：请求体与预期字节完全一致', () {
      final Map<String, Object?> body = buildAnthropicRequest(
        ProviderRequest(
          model: _noCache,
          systemPrompt: 'S',
          messages: <ChatMessageModel>[ChatMessageModel.user('U')],
        ),
      );

      // 改动构造顺序或字段名会让这条失败——这正是它存在的意义。
      expect(
        jsonEncode(body),
        equals(
          '{"model":"claude-plain","max_tokens":8000,'
          '"system":[{"type":"text","text":"S"}],'
          '"messages":[{"role":"user","content":[{"type":"text","text":"U"}]}],'
          '"stream":true}',
        ),
      );
    });
  });
}

bool _hasCacheControl(Object? message) {
  final List<Object?> blocks =
      (message! as Map<String, Object?>)['content'] as List<Object?>;
  return blocks.any(
    (Object? b) => (b! as Map<String, Object?>).containsKey('cache_control'),
  );
}

int _countCacheControl(Object? node) {
  if (node is Map<String, Object?>) {
    int count = node.containsKey('cache_control') ? 1 : 0;
    for (final Object? value in node.values) {
      count += _countCacheControl(value);
    }
    return count;
  }
  if (node is List<Object?>) {
    int count = 0;
    for (final Object? item in node) {
      count += _countCacheControl(item);
    }
    return count;
  }
  return 0;
}
