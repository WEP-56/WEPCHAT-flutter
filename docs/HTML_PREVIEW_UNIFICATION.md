# HTML 预览行为统一

## 改进内容

### 问题
- **改进前**：Android 使用应用内浏览器，Windows 使用系统默认浏览器
- **体验不一致**：不同平台有不同的预览方式
- **缺少源码查看**：无法在应用内快速查看 HTML 源码

### 解决方案

#### 1. 创建统一的 HTML 查看器
**新增文件**：`lib/ui/viewers/html_viewer_screen.dart`

**功能特性**：
- ✅ 全屏 HTML 预览（基于 InAppWebView）
- ✅ 预览/源码双模式切换
- ✅ 预览模式：刷新按钮
- ✅ 源码模式：复制按钮、可选择文本
- ✅ 加载进度条
- ✅ 错误处理和提示
- ✅ Android、Windows 统一体验

**UI 布局**：
```
[关闭] filename.html         [预览|源码] [刷新/复制]
─────────────────────────────────────────────────
│                                               │
│  预览模式：InAppWebView 渲染                    │
│  源码模式：可选择的代码文本                      │
│                                               │
─────────────────────────────────────────────────
```

#### 2. 统一导航逻辑
**修改文件**：`lib/app/app_nav.dart`

**改进前**：
```dart
if (Platform.isAndroid) {
  // 应用内浏览器
} else {
  // Windows 系统默认浏览器
}
```

**改进后**：
```dart
// Android、Windows 统一使用应用内预览
await Navigator.of(context).push<void>(
  MaterialPageRoute<void>(
    builder: (_) => HtmlViewerScreen(filePath: checked.absolute),
  ),
);
```

#### 3. 更新右键菜单
**修改文件**：`lib/ui/workspace/workspace_panel.dart`

**改进**：
- 移除条件判断：`file.kind == FileKind.html ? '在浏览器中预览' : '预览'`
- 统一为：`'预览'`

---

## 功能对比

| 特性 | 改进前（Windows） | 改进前（Android） | 改进后（统一） |
|------|------------------|------------------|---------------|
| **预览方式** | 系统浏览器 | 应用内浏览器 | 应用内浏览器 ✅ |
| **源码查看** | ❌ 需要打开编辑器 | ❌ 无法查看 | ✅ 内置源码模式 |
| **快速切换** | ❌ | ❌ | ✅ 预览/源码切换 |
| **刷新** | 浏览器自带 | 应用内 | 应用内 ✅ |
| **复制源码** | ❌ | ❌ | ✅ 一键复制 |
| **体验一致** | ❌ | ❌ | ✅ 跨平台统一 |

---

## 使用场景

### 工作区右侧边栏
1. 点击 `.html` 文件
2. 全屏打开预览界面
3. 默认显示渲染效果

### 预览/源码切换
- **预览模式**：查看页面渲染效果，测试交互
- **源码模式**：查看 HTML 代码，复制粘贴

### 典型工作流
```
工作区点击 index.html
    ↓
[预览] 模式 - 查看页面效果
    ↓
发现问题，切换到 [源码]
    ↓
复制相关代码片段
    ↓
回到聊天区，向 LLM 反馈问题
```

---

## 技术实现

### 预览模式
- 使用 `InAppWebView` 渲染 HTML
- 支持 JavaScript、DOM Storage
- 允许 file:// 协议的跨域访问
- 显示加载进度条
- 错误处理和重新加载

### 源码模式
- 读取文件内容为字符串
- 使用 `SelectionArea` 包裹，支持文本选择
- 等宽字体显示，保持代码格式
- 提供一键复制功能

### 安全性
- 路径校验：通过 `WorkspaceGuard` 确保只访问工作区内文件
- 不允许任意文件路径
- 错误提示：路径无效时显示友好错误

---

## 代码改动

### 新增文件
- ✅ `lib/ui/viewers/html_viewer_screen.dart` - HTML 预览查看器

### 修改文件
- ✅ `lib/app/app_nav.dart` - 统一 HTML 打开逻辑
- ✅ `lib/ui/workspace/workspace_panel.dart` - 更新右键菜单文案

### 删除依赖
- ✅ 移除 `app_nav.dart` 中的 `dart:io`、`path`、`open_file.dart` 导入
- ✅ 不再使用 `openFileInDefaultApp` 和 `BrowserPage`

---

## 测试验证

- ✅ `flutter analyze` - 无错误
- ✅ Windows 平台：HTML 在应用内打开
- ✅ Android 平台：行为保持一致
- ✅ 预览/源码切换流畅
- ✅ 错误处理正常

---

## 用户体验提升

1. **统一性**：Android、Windows 完全相同的体验
2. **便捷性**：预览、源码一键切换，无需跳转编辑器
3. **效率**：应用内完成所有操作，无需打开外部浏览器
4. **直观性**：图标和文案清晰，预览/源码语义明确

---

## 完成状态

✅ **所有功能已实现并验证通过**

- HTML 预览统一为应用内全屏查看
- 预览/源码双模式切换
- Android、Windows 体验一致
- 代码质量无问题
