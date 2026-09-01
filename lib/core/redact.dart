/// 日志脱敏。所有 log 出口只走这一个函数（AGENTS.md §1.2 §2.4）。
///
/// 去掉：API key（`sk-*`）、`Authorization` 头、独立的 Bearer token、
/// 绝对路径里的用户名段。
///
/// 这是强制入口，不是各处自觉。新增日志时不要绕过它。
String redact(String text) {
  String result = text;

  // 顺序有意义：先整条 Authorization 头，再处理独立出现的 Bearer token。
  // 反过来做会让 Bearer 规则先命中，Authorization 规则随后只吃掉 scheme，
  // 把已替换的占位符留在后面，产出 `Authorization: <REDACTED> <REDACTED_TOKEN>`。
  result = result.replaceAll(_authorizationHeader, 'Authorization: <REDACTED>');
  result = result.replaceAll(_apiKey, '<REDACTED_API_KEY>');
  result = result.replaceAll(_bearerToken, 'Bearer <REDACTED_TOKEN>');

  result = result.replaceAllMapped(
    _windowsUserDir,
    // group(1) 保留原始大小写与盘符，例如 `C:\Users\` / `d:\users\`。
    (Match m) => '${m.group(1)}<USER>\\',
  );
  result = result.replaceAll(_unixHomeDir, '/home/<USER>/');

  return result;
}

/// `Authorization: <scheme> <token>`，连 scheme 一起吃掉。
final RegExp _authorizationHeader = RegExp(
  r'Authorization:\s*[^\s,;]+(?:\s+[^\s,;]+)?',
  caseSensitive: false,
);

/// OpenAI 风格的密钥。20 字符下限避免误伤 `sk-` 开头的普通单词。
final RegExp _apiKey = RegExp(r'sk-[A-Za-z0-9_-]{20,}');

/// 不在 Authorization 头里的 Bearer token（例如出现在请求体或错误信息中）。
final RegExp _bearerToken = RegExp(
  r'Bearer\s+[A-Za-z0-9_\-.]{16,}',
  caseSensitive: false,
);

final RegExp _windowsUserDir = RegExp(
  r'([A-Za-z]:\\Users\\)[^\\/:*?"<>|]+\\',
  caseSensitive: false,
);

final RegExp _unixHomeDir = RegExp(r'/home/[^/]+/');
