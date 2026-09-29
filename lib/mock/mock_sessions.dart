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
