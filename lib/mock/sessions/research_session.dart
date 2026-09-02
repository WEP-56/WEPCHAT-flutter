import '../../models/chat.dart';
import '../../models/content.dart';
import '../../models/tool_call.dart';
import '../../models/workspace.dart';

/// 会话 s2：web_search 发现来源 + web_fetch 专一读取。
const ChatSession kResearchSession = ChatSession(
  id: 's2',
  title: '向量数据库选型调研',
  group: '今天',
  time: '11:05',
  preview: '嵌入式方案更符合 local-first 边界，已整理对比表',
  model: 'Claude Sonnet 4.5',
  files: <WorkspaceFile>[
    WorkspaceFile(
      name: 'vector_db_comparison.md',
      kind: FileKind.md,
      size: '3.1 KB',
      time: '今天 11:05',
    ),
    WorkspaceFile(
      name: 'sources.json',
      kind: FileKind.json,
      size: '1.1 KB',
      time: '今天 11:02',
    ),
  ],
  messages: <ChatMessage>[
    ChatMessage(
      id: 's2-m1',
      role: ChatRole.user,
      time: '10:58',
      blocks: <ContentBlock>[
        ParagraphBlock('帮我调研适合本地优先应用的向量数据库，重点看能不能嵌入式部署，不要后台服务。'),
      ],
    ),
    ChatMessage(
      id: 's2-m2',
      role: ChatRole.assistant,
      time: '11:05',
      tools: <ToolCall>[
        ToolCall(
          id: 's2-t1',
          kind: ToolKind.search,
          title: '联网搜索',
          query: '本地优先 向量数据库 嵌入式 Android Windows 2026',
          found: '找到 5 条来源，保留 3 条可引用结果',
          sources: <SourceChip>[
            SourceChip('sqlite-vec 0.3 发布说明', 'github.com'),
            SourceChip('Qdrant 部署形态对比', 'qdrant.tech'),
            SourceChip('移动端向量检索实践', 'infoq.cn'),
          ],
          duration: '1.8s',
        ),
        ToolCall(
          id: 's2-t2',
          kind: ToolKind.fetch,
          title: '读取网页',
          meta: 'target=s1 · max_chars=20000',
          detail: '提取正文 8.2 KB，含构建产物与平台支持矩阵。',
          duration: '0.9s',
        ),
        ToolCall(
          id: 's2-t3',
          kind: ToolKind.file,
          title: '写入文件',
          meta: 'path=vector_db_comparison.md · 3.1 KB',
          detail: '整理为对比表 + 结论清单。',
          duration: '0.1s',
        ),
      ],
      blocks: <ContentBlock>[
        ParagraphBlock(
          '三个候选方案里，只有 **sqlite-vec** 能同时满足嵌入式部署和 Android / Windows 双端 [1]：',
        ),
        TableBlock(
          <String>['方案', '部署形态', '跨平台', '适用规模'],
          <TableRowData>[
            TableRowData(<String>[
              'sqlite-vec',
              '嵌入式',
              'Android / Windows',
              '十万级',
            ]),
            TableRowData(<String>['Qdrant', '独立服务', '需服务端', '百万级'], neg: true),
            TableRowData(<String>[
              'Chroma',
              'Python 进程',
              '不适合移动端',
              '十万级',
            ], neg: true),
          ],
        ),
        BulletListBlock(<String>[
          'sqlite-vec 以扩展形式随包发布，不额外引入后台进程 [1]。',
          'Qdrant 性能更好，但需要独立服务端，超出轻量客户端边界 [2]。',
          '移动端检索建议控制在十万向量以内，再往上要考虑分片 [3]。',
        ]),
        QuoteBlock('结论：第一版走 sqlite-vec；独立服务方案留作后续可选扩展。'),
      ],
      files: <String>['vector_db_comparison.md', 'sources.json'],
    ),
  ],
);
