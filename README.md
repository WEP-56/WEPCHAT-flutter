# WePChat

轻量级 AI 聊天客户端（Windows / Android），采用本地优先设计：会话、设置、工作区文件均存储在本地。

## ✨ 核心特性

### 💬 多协议 LLM 对话
- 支持三种主流协议：`anthropic-messages`、`openai-completions`、`openai-responses`
- 流式输出、实时中断
- Markdown 渲染：代码高亮、表格、列表、引用
- 思考模式支持（extended thinking）

### 🔧 灵活的提供商配置
- 自定义提供商：名称、API 类别、baseUrl、API Key
- 模型管理：从 `/models` 端点拉取或手动添加
- 单模型连通性测试
- 兼容性标记可逐项调整

### 🤖 Agent 与工具系统
- **Agent Loop**：多轮工具调用、流式输出、错误恢复
- **内置工具**：
  - 文件操作（读/写/搜索）
  - 工作区管理
  - 全局记忆（三层结构：用户画像、用户倾向、波动区域）
  - Bash 命令执行
- **工具权限**：细粒度控制（禁止/询问/允许）

### 💾 本地优先存储
- SQLite 持久化：会话、消息、工具调用、记忆
- 追加式日志设计：支持编辑重发、模型切换、会话压缩
- 工作区文件系统：每个会话独立目录
- 增量备份与恢复

### 🖼️ 工作区与预览
- 文件浏览器：图片画廊、文件列表、快速导出
- 内置预览器：
  - **HTML**：应用内预览 + 源码查看（双模式切换）
  - **图片**：轻量级查看器、画廊模式
  - **文本/代码**：语法高亮
- 路径安全校验：防止越界访问

### 🧠 全局记忆系统
- LLM 自主维护的工作笔记本
- 三层分类：
  - `user_profile` - 长期用户画像
  - `user_preference` - 中期偏好设置
  - `volatile` - 短期临时信息
- 工具驱动：`save_memory`、`list_memory`、`read_memory`、`delete_memory`
- UI 管理：查看、编辑、删除

### ⚙️ 其他特性
- 会话管理：创建、重命名、删除、恢复
- 深色/浅色主题（跟随系统或手动切换）
- 跨平台一致体验（Windows、Android）
- 无障碍优化

---

## 🔒 隐私与安全

### API Key 存储
- 位置：`<应用数据目录>/settings.json`
- 界面永不显示明文，仅显示掩码（前 6 + 后 4 字符）
- 日志输出自动脱敏
- Android：私有目录，未 root 无法访问
- Windows：明文存储（可扩展 DPAPI 加密）

### 数据隔离
- 每个会话独立工作区目录
- 路径校验防止越界访问
- 用户数据不上传（除主动配置的 API 调用）

---

## 🚀 快速开始

### 环境要求
- Flutter SDK >= 3.24.0
- Dart SDK >= 3.5.0
- Android Studio (Android 开发)
- Visual Studio 2022 (Windows 开发)

### 安装依赖
```bash
flutter pub get
```

### 运行
```bash
# Windows
flutter run -d windows

# Android
flutter run -d <device_id>
```

### 首次启动
1. 进入「设置 → 模型服务」
2. 添加提供商（名称、API 类别、baseUrl、Key）
3. 添加或拉取模型
4. 返回主界面开始对话

---

## 🧪 开发与测试

### 代码检查
```bash
# 格式化
dart format --set-exit-if-changed .

# 静态分析
flutter analyze

# 单元测试
flutter test

# 集成测试（需要模拟器/设备）
flutter test integration_test/
```

### 项目结构
```
lib/
├── agent/          # Agent Loop 实现
├── ai/             # LLM 协议适配器
├── browser/        # 应用内浏览器（Android）
├── models/         # 数据模型
├── platform/       # 平台特定代码
├── state/          # 状态管理（Provider）
├── storage/        # SQLite 存储层
├── tools/          # 工具实现
├── ui/             # Flutter UI 组件
└── main.dart       # 应用入口

docs/               # 设计文档
test/               # 单元测试
integration_test/   # 集成测试
```

---

## 📚 文档

| 文件 | 说明 |
|------|------|
| [docs/HANDOFF.md](docs/HANDOFF.md) | **从这里开始** - 代码现状、架构决策、已知问题 |
| [docs/WePChat-Flutter-功能与工具协议.md](docs/WePChat-Flutter-功能与工具协议.md) | 工具系统设计、权限模型、记忆系统 |
| [docs/WePChat-Flutter-会话存储设计.md](docs/WePChat-Flutter-会话存储设计.md) | 存储层完整设计、迁移策略 |
| [docs/WePChat-Flutter-实施TODO.md](docs/WePChat-Flutter-实施TODO.md) | 施工清单（代码中的 §X 引用此文档） |
| [AGENTS.md](AGENTS.md) | 工程约束与开发规范 |
| [docs/MEMORY_IMPLEMENTATION.md](docs/MEMORY_IMPLEMENTATION.md) | 全局记忆功能实施总结 |
| [docs/HTML_PREVIEW_UNIFICATION.md](docs/HTML_PREVIEW_UNIFICATION.md) | HTML 预览统一说明 |

---

## 🛠️ 技术栈

- **框架**：Flutter 3.24+
- **状态管理**：Provider
- **数据库**：SQLite (via sqlite3 & ffi)
- **HTTP**：http 包
- **WebView**：flutter_inappwebview
- **路径处理**：path 包
- **其他**：url_launcher、file_picker、file_selector

---

## 📦 构建发布

### Android APK
```bash
flutter build apk --release
# 输出: build/app/outputs/flutter-apk/app-release.apk
```

### Android App Bundle (推荐上传 Play Store)
```bash
flutter build appbundle --release
# 输出: build/app/outputs/bundle/release/app-release.aab
```

### Windows
```bash
flutter build windows --release
# 输出: build/windows/x64/runner/Release/
```

**签名说明**：Android 发布签名配置位于 `android/key.properties`（已在 `.gitignore` 中排除）

---

## 🤝 贡献

欢迎提交 Issue 和 Pull Request！

### 开发原则
1. 本地优先：用户数据不依赖云端
2. 隐私保护：API Key 和用户数据严格保护
3. 跨平台一致：Windows 和 Android 体验统一
4. 代码质量：通过 `flutter analyze` 和 `flutter test`
5. 文档同步：重大改动更新对应文档

---

## 📄 许可证

MIT License

---

## 🔗 相关链接

- 仓库：https://github.com/WEP-56/WEPCHAT-flutter
- Issues：https://github.com/WEP-56/WEPCHAT-flutter/issues

---

## 版本历史

- **v0.3.0** (2026-09-03) - 全局记忆系统、HTML 预览统一
- **v0.2.0** (2026-09-02) - Agent Loop、工具系统、工作区管理
- **v0.1.0** (2026-08-31) - 基础聊天、多协议支持、会话持久化
