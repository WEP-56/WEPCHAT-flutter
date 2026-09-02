/// 纯前端阶段的工作区默认值与图片资源映射。
///
/// 接入真实存储后，这里会被 `wep_storage` 提供的会话工作区替换。
library;

/// 会话工作区内的图片相对路径 → 打包资源路径。
///
/// 纯前端阶段没有真实文件系统读取，用少量内置图片让画面接近真机效果；
/// 未收录的图片走渐变占位图。
const Map<String, String> kWorkspaceImageAssets = <String, String>{
  'images/cover_coffee_v1.jpg': 'assets/images/cover_coffee_v1.jpg',
  'images/cover_coffee_v2.jpg': 'assets/images/cover_coffee_v2.jpg',
};

/// 可选聊天模型（设置页与会话模型切换共用同一份清单）。
const List<String> kAvailableModels = <String>[
  'GPT-5',
  'Claude Sonnet 4.5',
  'Gemini 2.5 Pro',
  'DeepSeek V3.2',
  'Qwen3 Max',
];

/// 上下文长度档位。
const List<String> kContextWindowOptions = <String>['32K', '128K', '200K'];
