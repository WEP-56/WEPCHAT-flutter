import '../../models/chat.dart';
import '../../models/content.dart';
import '../../models/tool_call.dart';
import '../../models/workspace.dart';

/// 会话 s4：HTML 产物 + 沙盒预览入口。
const ChatSession kChecklistSession = ChatSession(
  id: 's4',
  title: '露营装备清单页面',
  group: '昨天',
  time: '20:12',
  preview: '单页清单已生成，样式拆到 checklist_style.css',
  model: 'GPT-5',
  files: <WorkspaceFile>[
    WorkspaceFile(
      name: 'camping_checklist.html',
      kind: FileKind.html,
      size: '4.6 KB',
      time: '昨天 20:12',
    ),
    WorkspaceFile(
      name: 'checklist_style.css',
      kind: FileKind.css,
      size: '1.8 KB',
      time: '昨天 20:11',
    ),
  ],
  messages: <ChatMessage>[
    ChatMessage(
      id: 's4-m1',
      isUser: true,
      time: '20:05',
      blocks: <ContentBlock>[
        ParagraphBlock('做一个露营装备清单的单页，能勾选，风格清爽一点，样式单独放一个文件。'),
      ],
    ),
    ChatMessage(
      id: 's4-m2',
      isUser: false,
      time: '20:12',
      tools: <ToolCall>[
        ToolCall(
          id: 's4-t1',
          kind: ToolKind.file,
          title: '写入文件',
          meta: 'path=checklist_style.css · 1.8 KB',
          detail: '样式变量集中在 :root，便于后续换色。',
          duration: '0.1s',
        ),
        ToolCall(
          id: 's4-t2',
          kind: ToolKind.file,
          title: '写入文件',
          meta: 'path=camping_checklist.html · 4.6 KB',
          detail: '外链样式表，勾选状态用少量内联脚本切换。',
          duration: '0.1s',
        ),
      ],
      blocks: <ContentBlock>[
        ParagraphBlock('页面分成 **睡眠系统 / 炊事 / 照明 / 杂物** 四组，勾选状态会加删除线。'),
      ],
      html: HtmlRef(
        file: 'camping_checklist.html',
        title: '露营装备清单',
        desc: '单页 · 可勾选 · 样式已拆分',
      ),
      files: <String>['camping_checklist.html', 'checklist_style.css'],
    ),
  ],
);

/// 会话 s5：PDF 附件 + 翻译产出 + 记忆写入。
const ChatSession kManualSession = ChatSession(
  id: 's5',
  title: '德语说明书翻译',
  group: '本周',
  time: '周三 16:40',
  preview: '已翻译前 8 页，术语表放在文末',
  model: 'Claude Sonnet 4.5',
  files: <WorkspaceFile>[
    WorkspaceFile(
      name: 'Bedienungsanleitung.pdf',
      kind: FileKind.pdf,
      size: '2.3 MB',
      time: '周三 16:31',
    ),
    WorkspaceFile(
      name: 'translation_de.md',
      kind: FileKind.md,
      size: '5.2 KB',
      time: '周三 16:40',
    ),
  ],
  messages: <ChatMessage>[
    ChatMessage(
      id: 's5-m1',
      isUser: true,
      time: '16:31',
      attachments: <Attachment>[
        Attachment(
          name: 'Bedienungsanleitung.pdf',
          size: '2.3 MB',
          kind: FileKind.pdf,
        ),
      ],
      blocks: <ContentBlock>[ParagraphBlock('把这份德语说明书的前几页翻成中文，专业术语保留原文。')],
    ),
    ChatMessage(
      id: 's5-m2',
      isUser: false,
      time: '16:40',
      tools: <ToolCall>[
        ToolCall(
          id: 's5-t1',
          kind: ToolKind.file,
          title: '读取文件',
          meta: 'path=Bedienungsanleitung.pdf · pages=1-8',
          detail: '提取可读文本 11.4 KB，图注未纳入。',
          duration: '1.1s',
        ),
        ToolCall(
          id: 's5-t2',
          kind: ToolKind.memory,
          title: '保存记忆',
          note: 'preference / reply_language = 默认用中文回答，术语保留原文',
          duration: '0.1s',
        ),
      ],
      blocks: <ContentBlock>[
        ParagraphBlock('前 8 页已翻译完成，写入 `translation_de.md`。首次使用部分摘录：'),
        BulletListBlock(<String>[
          '取下水箱，注入不超过 **1.2 L** 的冷水。',
          '首次通电后执行一次空冲洗程序。',
          '指示灯由橙色转为白色即表示预热完成。',
        ], ordered: true),
        QuoteBlock('Achtung：除水垢期间请勿断电，否则程序需要重新开始。'),
      ],
      files: <String>['translation_de.md'],
    ),
  ],
);
