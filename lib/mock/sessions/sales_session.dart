import '../../models/chat.dart';
import '../../models/content.dart';
import '../../models/tool_call.dart';
import '../../models/workspace.dart';

/// 会话 s1：CSV 汇总 + run_js + 文件产出。
const ChatSession kSalesSession = ChatSession(
  id: 's1',
  title: 'Q2 销售数据汇总脚本',
  group: '今天',
  time: '14:32',
  preview: '已按区域汇总 2026 Q2 数据，脚本结果写入工作区',
  model: 'GPT-5',
  files: <WorkspaceFile>[
    WorkspaceFile(
      name: 'sales_q2.csv',
      kind: FileKind.csv,
      size: '48 KB',
      time: '今天 14:20',
    ),
    WorkspaceFile(
      name: 'summarize_sales.py',
      kind: FileKind.py,
      size: '1.2 KB',
      time: '今天 14:26',
    ),
    WorkspaceFile(
      name: 'sales_summary_q2.csv',
      kind: FileKind.csv,
      size: '0.9 KB',
      time: '今天 14:31',
    ),
    WorkspaceFile(
      name: 'report_q2.md',
      kind: FileKind.md,
      size: '2.4 KB',
      time: '今天 14:32',
    ),
  ],
  messages: <ChatMessage>[
    ChatMessage(
      id: 's1-m1',
      role: ChatRole.user,
      time: '14:28',
      attachments: <Attachment>[
        Attachment(name: 'sales_q2.csv', size: '48 KB', kind: FileKind.csv),
      ],
      blocks: <ContentBlock>[
        ParagraphBlock('这是 Q2 的原始销售数据，帮我按区域汇总，给一个表格和简短结论。'),
      ],
    ),
    ChatMessage(
      id: 's1-m2',
      role: ChatRole.assistant,
      time: '14:31',
      tools: <ToolCall>[
        ToolCall(
          id: 's1-t1',
          kind: ToolKind.file,
          title: '读取文件',
          meta: 'path=sales_q2.csv · lines=1-40',
          detail: '共 186 行，覆盖 4—6 月两个区域的月度记录。',
          duration: '0.2s',
        ),
        ToolCall(
          id: 's1-t2',
          kind: ToolKind.script,
          title: '运行 JavaScript',
          meta: 'timeout=10s · 输出 1.3 KB',
          detail: '按区域聚合营收与订单量，写出 sales_summary_q2.csv。',
          duration: '1.4s',
        ),
      ],
      blocks: <ContentBlock>[
        ParagraphBlock(
          '已按区域汇总 **2026 Q2** 数据，聚合结果写入工作区的 `sales_summary_q2.csv`：',
        ),
        TableBlock(
          <String>['区域', '营收', '占比', '环比'],
          <TableRowData>[
            TableRowData(<String>['华东', '419.8 万', '61.0%', '+11.4%']),
            TableRowData(<String>[
              '华南',
              '264.0 万',
              '38.4%',
              '-8.2%',
            ], neg: true),
            TableRowData(<String>['其他', '4.1 万', '0.6%', '+1.1%']),
          ],
        ),
        CodeBlock('javascript', '''
const rows = parseCsv(await wep.fs.readText("sales_q2.csv"));
const byRegion = new Map();
for (const row of rows) {
  const prev = byRegion.get(row.region) ?? 0;
  byRegion.set(row.region, prev + Number(row.revenue));
}
await wep.fs.writeText("sales_summary_q2.csv", toCsv(byRegion));
''', title: 'run_js'),
        ParagraphBlock('华南从 5 月起连续下滑，建议先核对渠道口径再做同比结论。'),
      ],
      files: <String>['sales_summary_q2.csv'],
    ),
    ChatMessage(
      id: 's1-m3',
      role: ChatRole.user,
      time: '14:32',
      blocks: <ContentBlock>[ParagraphBlock('把结论单独写成 report_q2.md，标题用一级标题。')],
    ),
    ChatMessage(
      id: 's1-m4',
      role: ChatRole.assistant,
      time: '14:32',
      tools: <ToolCall>[
        ToolCall(
          id: 's1-t3',
          kind: ToolKind.file,
          title: '写入文件',
          meta: 'path=report_q2.md · 2.4 KB',
          detail: '新建文件，父目录已存在。',
          duration: '0.1s',
        ),
      ],
      blocks: <ContentBlock>[
        ParagraphBlock('已写入 `report_q2.md`，包含区域表现表格和三条结论，可以直接在工作区里打开查看。'),
      ],
      files: <String>['report_q2.md'],
    ),
  ],
);
