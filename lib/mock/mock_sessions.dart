import '../models/chat.dart';
import 'sessions/artifact_sessions.dart';
import 'sessions/cover_session.dart';
import 'sessions/research_session.dart';
import 'sessions/sales_session.dart';

/// 会话列表的初始数据（纯前端阶段）。
const List<ChatSession> kMockSessions = <ChatSession>[
  kSalesSession,
  kResearchSession,
  kCoverSession,
  kChecklistSession,
  kManualSession,
];

/// 会话列表分组顺序。未列出的分组排在最后。
const List<String> kSessionGroupOrder = <String>['今天', '昨天', '本周', '更早'];
