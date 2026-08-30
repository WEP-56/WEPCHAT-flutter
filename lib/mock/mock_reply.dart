import '../models/chat.dart';
import '../models/content.dart';
import '../models/tool_call.dart';

/// 纯前端阶段的假回复。
///
/// 这里刻意不做任何“看起来像真的”的推断：只根据关键词挑一条固定文案，
/// 让工具卡片、表格、代码块等渲染分支都能在真机上被点到。
/// 接入 Agent Core 后整个文件会被删除。
abstract final class MockReply {
  static ChatMessage placeholder({required String id, required String time}) {
    return ChatMessage(id: id, isUser: false, time: time, isStreaming: true);
  }

  static ChatMessage complete({
    required String id,
    required String time,
    required String userText,
  }) {
    final _ReplyShape shape = _shapeFor(userText);
    return ChatMessage(
      id: id,
      isUser: false,
      time: time,
      tools: shape.tools,
      blocks: shape.blocks,
    );
  }

  static _ReplyShape _shapeFor(String text) {
    if (_containsAny(text, <String>['搜', '查一下', '最新', '资料'])) {
      return const _ReplyShape(
        tools: <ToolCall>[
          ToolCall(
            id: 'mock-search',
            kind: ToolKind.search,
            title: '联网搜索',
            query: '（预览数据）当前输入对应的检索词',
            found: '找到 3 条来源',
            sources: <SourceChip>[
              SourceChip('示例来源 A', 'example.com'),
              SourceChip('示例来源 B', 'docs.example.org'),
            ],
            duration: '1.2s',
          ),
        ],
        blocks: <ContentBlock>[
          ParagraphBlock('这是**前端预览回复**：搜索结果、引用角标 [1] 与来源卡片的渲染都在这里演示。'),
          BulletListBlock(<String>[
            '联网工具尚未接入，返回的是固定文案。',
            '真实实现会走 `web_search` → `web_fetch`。',
          ]),
        ],
      );
    }
    if (_containsAny(text, <String>['图', '封面', '画'])) {
      return const _ReplyShape(
        tools: <ToolCall>[
          ToolCall(
            id: 'mock-image',
            kind: ToolKind.image,
            title: '图片生成',
            prompt: '（预览数据）根据当前输入构造的提示词',
            meta: 'size=1024×576 · count=1',
            detail: '预览版本不调用真实图片接口。',
            duration: '0.4s',
          ),
        ],
        blocks: <ContentBlock>[
          ParagraphBlock('这是**前端预览回复**：图片工具已连通 UI，但没有真实产物写入工作区。'),
        ],
      );
    }
    if (_containsAny(text, <String>['代码', '脚本', '写个', 'js', 'python'])) {
      return const _ReplyShape(
        tools: <ToolCall>[
          ToolCall(
            id: 'mock-script',
            kind: ToolKind.script,
            title: '运行 JavaScript',
            meta: 'timeout=10s · 输出 0.2 KB',
            detail: '预览版本不执行真实沙盒。',
            duration: '0.3s',
          ),
        ],
        blocks: <ContentBlock>[
          ParagraphBlock('这是**前端预览回复**，用来检查代码块的换行、横向滚动和复制按钮：'),
          CodeBlock('javascript', '''
const text = await wep.fs.readText("input.txt");
const words = text.split(/\\s+/).filter(Boolean);
console.log(`共 \${words.length} 个词`);
''', title: 'preview.js'),
        ],
      );
    }
    return const _ReplyShape(
      tools: <ToolCall>[],
      blocks: <ContentBlock>[
        ParagraphBlock('这是**前端预览回复**。当前工程只有界面与少量 mock 数据，模型调用、工具执行和持久化都还没有接入。'),
        ParagraphBlock(
          '可以试试这些输入，观察不同渲染分支：`搜索一下 Flutter QuickJS`、`帮我做一张封面`、`写个脚本统计词频`。',
        ),
      ],
    );
  }

  static bool _containsAny(String text, List<String> keywords) {
    final String lower = text.toLowerCase();
    for (final String keyword in keywords) {
      if (lower.contains(keyword)) return true;
    }
    return false;
  }
}

class _ReplyShape {
  const _ReplyShape({required this.tools, required this.blocks});

  final List<ToolCall> tools;
  final List<ContentBlock> blocks;
}
