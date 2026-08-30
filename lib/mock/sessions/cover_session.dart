import '../../models/chat.dart';
import '../../models/content.dart';
import '../../models/tool_call.dart';
import '../../models/workspace.dart';

/// 会话 s3：gen_image / edit_image，产物写入工作区。
const ChatSession kCoverSession = ChatSession(
  id: 's3',
  title: '公众号封面：清晨咖啡店',
  group: '今天',
  time: '09:52',
  preview: '第二版把光线调暖，杯子右移，已存入工作区',
  model: 'Gemini 2.5 Pro',
  files: <WorkspaceFile>[
    WorkspaceFile(
      name: 'images/cover_coffee_v1.jpg',
      kind: FileKind.jpg,
      size: '110 KB',
      time: '今天 09:44',
    ),
    WorkspaceFile(
      name: 'images/cover_coffee_v2.jpg',
      kind: FileKind.jpg,
      size: '149 KB',
      time: '今天 09:52',
    ),
  ],
  messages: <ChatMessage>[
    ChatMessage(
      id: 's3-m1',
      isUser: true,
      time: '09:41',
      blocks: <ContentBlock>[
        ParagraphBlock('做一张公众号封面，主题是清晨的咖啡店，暖色调，横版，留一点空白放标题。'),
      ],
    ),
    ChatMessage(
      id: 's3-m2',
      isUser: false,
      time: '09:44',
      tools: <ToolCall>[
        ToolCall(
          id: 's3-t1',
          kind: ToolKind.image,
          title: '图片生成',
          prompt: '清晨咖啡店，木质吧台，斜射晨光，浅景深，暖色调，横版 16:9，右上留白',
          meta: 'size=1024×576 · count=1',
          detail: '已写入 images/cover_coffee_v1.jpg。',
          duration: '6.2s',
        ),
      ],
      blocks: <ContentBlock>[ParagraphBlock('第一版出来了，右上角留了标题位：')],
      images: <ImageResult>[
        ImageResult(
          file: 'images/cover_coffee_v1.jpg',
          meta: '1024×576 · JPG · 高质量',
        ),
      ],
      files: <String>['images/cover_coffee_v1.jpg'],
    ),
    ChatMessage(
      id: 's3-m3',
      isUser: true,
      time: '09:49',
      blocks: <ContentBlock>[ParagraphBlock('光线再暖一点，杯子往右移一些，其他保持不变。')],
    ),
    ChatMessage(
      id: 's3-m4',
      isUser: false,
      time: '09:52',
      tools: <ToolCall>[
        ToolCall(
          id: 's3-t2',
          kind: ToolKind.image,
          title: '图片编辑',
          prompt: '提高色温到暖调，主体咖啡杯右移约 15%，保留原有构图与景深',
          meta: 'image_file=images/cover_coffee_v1.jpg',
          detail: '编辑结果另存为新文件，原图保留。',
          duration: '5.4s',
        ),
      ],
      blocks: <ContentBlock>[ParagraphBlock('第二版已生成，原图没有被覆盖，两版都在工作区里：')],
      images: <ImageResult>[
        ImageResult(
          file: 'images/cover_coffee_v2.jpg',
          meta: '1024×576 · JPG · 高质量',
        ),
      ],
      files: <String>['images/cover_coffee_v2.jpg'],
    ),
  ],
);
