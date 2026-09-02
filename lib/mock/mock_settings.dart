import 'package:flutter/material.dart';

import '../models/settings.dart';

const List<ProviderInfo> kProviders = <ProviderInfo>[
  ProviderInfo(
    id: 'openai',
    name: 'OpenAI',
    badgeColor: Color(0xFF10A37F),
    connected: true,
    maskedKey: 'sk-proj-••••••••••••7f2a',
    models: <String>['GPT-5', 'GPT-5 mini', 'o4-mini'],
  ),
  ProviderInfo(
    id: 'anthropic',
    name: 'Anthropic',
    badgeColor: Color(0xFFD97757),
    connected: true,
    maskedKey: 'sk-ant-••••••••••••9c41',
    models: <String>['Claude Sonnet 4.5', 'Claude Haiku 4.5'],
  ),
  ProviderInfo(
    id: 'google',
    name: 'Google',
    badgeColor: Color(0xFF4285F4),
    connected: false,
    maskedKey: '未配置',
    models: <String>['Gemini 2.5 Pro', 'Gemini 2.5 Flash'],
  ),
  ProviderInfo(
    id: 'custom',
    name: '自定义通道',
    badgeColor: Color(0xFF7C5CFF),
    connected: true,
    maskedKey: 'https://api.example.com/v1',
    models: <String>['DeepSeek V3.2', 'Qwen3 Max'],
  ),
];

/// 权限档位默认值对齐功能协议 §9 的建议表。
///
/// 已移到 `lib/models/settings.dart`：它不是原型假数据，而是真实设置的
/// 权威定义（`AppSettings` 读它作默认值，权限门读它取显示名），放在
/// `mock/` 下会逼着 `tools/` 反向依赖原型层。

const List<SearchBackendSpec> kSearchBackends = <SearchBackendSpec>[
  SearchBackendSpec(
    id: 'tavily',
    name: 'Tavily',
    desc: '面向 LLM 的搜索 API，返回摘要与来源',
  ),
  SearchBackendSpec(id: 'brave', name: 'Brave Search', desc: '独立索引，需要单独申请 Key'),
  SearchBackendSpec(id: 'searxng', name: 'SearXNG', desc: '自建实例，填写实例地址即可'),
  SearchBackendSpec(id: 'openai', name: 'OpenAI 原生搜索', desc: '复用聊天 Key，按供应商计费'),
  SearchBackendSpec(
    id: 'anthropic',
    name: 'Anthropic 原生搜索',
    desc: '复用聊天 Key，返回引用块',
  ),
];

const List<MemoryEntry> kMemoryEntries = <MemoryEntry>[
  MemoryEntry(
    id: 'pref_ui_style',
    category: 'preference',
    key: 'ui_style',
    value: '偏好简洁、低干扰的界面，不喜欢过多动画',
    updatedAt: '2026-08-24',
  ),
  MemoryEntry(
    id: 'pref_lang',
    category: 'preference',
    key: 'reply_language',
    value: '默认用中文回答，代码注释保持英文',
    updatedAt: '2026-08-21',
  ),
  MemoryEntry(
    id: 'ctx_work',
    category: 'context',
    key: 'daily_work',
    value: '主要做数据分析，常处理 CSV 与月度销售报表',
    updatedAt: '2026-08-18',
  ),
  MemoryEntry(
    id: 'ctx_device',
    category: 'context',
    key: 'devices',
    value: '同时使用 Windows 台式机和 Android 手机，需要两端体验一致',
    updatedAt: '2026-08-12',
  ),
];
