# WePChat

轻量 LLM 聊天客户端（Windows / Android）。本地优先：会话、设置、工作区文件都存在本机。

## 现在能做什么

- 三种协议的纯聊天，流式输出，可中断：
  `anthropic-messages`、`openai-completions`、`openai-responses`
- 自己配提供商：名称、API 类别、baseUrl、Key 四项。模型可以从 `/models` 拉取后勾选，
  也可以手填；每个模型能单独「发一句 hi」测通不通，也能逐项改兼容标记
- 会话持久化（SQLite），重启后历史还在
- 助手回复渲染 Markdown 块：标题、代码块、列表、引用、表格

还没有工具（文件读写、搜索、图片）——那是 M2 及以后。

## API Key 存在哪

`<应用数据目录>/settings.json`，和数据库同一个私有目录。**界面永不显示明文**，
只显示掩码（前 6 + 后 4）；日志和输出一律过 `redact()`。

Android 私有目录未 root 拿不到；Windows 上这个文件是明文可读的——要改善得写
DPAPI 平台通道，对这个体量的项目工作量与收益不成比例。将来要加密只需换
`lib/platform/settings_store.dart` 的读写两个方法。理由见实施 TODO §13.4。

## 跑起来

```bash
flutter pub get
flutter run -d windows
```

首次启动没有任何 Key，去「设置 → 模型服务」填一个提供商再添加模型。

## 检查

```bash
dart format --set-exit-if-changed .
flutter analyze
flutter test
```

## 文档

| 文件 | 内容 |
|---|---|
| `docs/HANDOFF-M2.md` | **从这里开始**。当前代码的真实形状、踩过的坑、M2 从哪下手 |
| `docs/WePChat-Flutter-实施TODO.md` | 施工清单。代码注释里的 `（§5-8）` 指的是这里的章节 |
| `docs/WePChat-Flutter-会话存储设计.md` | 存储层完整设计 |
| `docs/WePChat-Flutter-功能与工具协议.md` | 工具与功能契约 |
| `AGENTS.md` | 工程约束 |
| `docs/M0-*.md` | 历史存档，有多处已不成立，开头都标了 |
