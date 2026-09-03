import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/app_nav.dart';
import '../../models/chat.dart';
import '../../models/workspace.dart';
import '../../platform/open_directory.dart';
import '../../platform/workspace_file_service.dart';
import '../../state/app_scope.dart';
import '../../state/session_store.dart';
import '../../theme/fonts.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/context_menu_region.dart' as context_menu;
import '../widgets/file_visuals.dart';
import '../widgets/segmented_control.dart';
import '../widgets/toast.dart';

enum _WorkspaceTab { files, images }

/// 右侧工作区面板：当前会话目录下的文件与图片。
class WorkspacePanel extends StatefulWidget {
  const WorkspacePanel({
    super.key,
    this.onCollapse,
    this.collapseIcon,
    this.embedded = false,
  });

  /// 宽屏折叠 / 窄屏关闭抽屉；为 null 时不显示该按钮。
  final VoidCallback? onCollapse;
  final IconData? collapseIcon;

  /// 桌面端嵌入内容面时与聊天区同色；抽屉继续使用独立面板色。
  final bool embedded;

  @override
  State<WorkspacePanel> createState() => _WorkspacePanelState();
}

class _WorkspacePanelState extends State<WorkspacePanel> {
  _WorkspaceTab _tab = _WorkspaceTab.files;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final SessionStore store = context.sessions;

    return Container(
      // 嵌入桌面内容面时只用轻微色差区分工作区，不画出实体边界。
      color: widget.embedded
          ? Color.alphaBlend(palette.bgSide.withValues(alpha: 0.22), palette.bg)
          : palette.bgPanel,
      child: SafeArea(
        child: ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[store, context.settings]),
          builder: (BuildContext context, Widget? _) {
            final ChatSession session = store.active;
            final List<WorkspaceFile> images = session.files
                .where((WorkspaceFile f) => f.isImage)
                .toList();
            final String path = sessionWorkspacePath(
              context.settings.workspaceRoot,
              session.id,
            );

            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _buildHeader(context, session.files.length),
                _buildPathChip(context, path),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
                  child: SegmentedControl<_WorkspaceTab>(
                    small: true,
                    expand: true,
                    value: _tab,
                    onChanged: (_WorkspaceTab tab) =>
                        setState(() => _tab = tab),
                    options: <SegOption<_WorkspaceTab>>[
                      const SegOption<_WorkspaceTab>(_WorkspaceTab.files, '文件'),
                      SegOption<_WorkspaceTab>(
                        _WorkspaceTab.images,
                        '图片 ${images.length}',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: switch (_tab) {
                    _WorkspaceTab.files => _buildFileList(
                      context,
                      session.files,
                    ),
                    _WorkspaceTab.images => _buildImageGrid(context, images),
                  },
                ),
                _buildFooter(context),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, int count) {
    final AppPalette palette = context.palette;
    return Container(
      height: 44,
      padding: const EdgeInsets.fromLTRB(12, 0, 6, 0),
      child: Row(
        children: <Widget>[
          Text(
            '工作区',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: palette.text1,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count 个文件',
            style: TextStyle(fontSize: 10.5, color: palette.text3),
          ),
          const Spacer(),
          IconAction(
            icon: Icons.upload_file_outlined,
            tooltip: '上传文件',
            onTap: () => _upload(context),
          ),
          IconAction(
            icon: Icons.note_add_outlined,
            tooltip: '新建文件',
            onTap: () => _createFile(context),
          ),
          IconAction(
            icon: Icons.create_new_folder_outlined,
            tooltip: '新建文件夹',
            onTap: () => _createDirectory(context),
          ),
          if (widget.onCollapse != null)
            IconAction(
              icon: widget.collapseIcon ?? Icons.chevron_right,
              tooltip: '收起',
              onTap: widget.onCollapse!,
            ),
        ],
      ),
    );
  }

  Widget _buildPathChip(BuildContext context, String path) {
    final AppPalette palette = context.palette;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: InkWell(
        onTap: () async {
          await Clipboard.setData(ClipboardData(text: path));
          if (!context.mounted) return;
          showAppToast(context, '路径已复制');
        },
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: palette.bgRaise,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: <Widget>[
              Icon(Icons.folder_outlined, size: 13, color: palette.text3),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  path,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.mono(size: 10.5, color: palette.text2),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildFileList(BuildContext context, List<WorkspaceFile> files) {
    if (files.isEmpty) return const _EmptyHint('本次会话还没有产物');
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      itemCount: files.length,
      itemBuilder: (BuildContext context, int index) {
        return _FileRow(file: files[index]);
      },
    );
  }

  WorkspaceFileService _service(BuildContext context) => WorkspaceFileService(
    context.sessions.workspacePathFor(context.sessions.active.id),
  );

  Future<void> _upload(BuildContext context) async {
    final SessionStore store = context.sessions;
    final WorkspaceFileService service = _service(context);
    final int count = await service.upload();
    if (!mounted) return;
    await store.refreshWorkspace();
    if (mounted) {
      showAppToast(this.context, count == 0 ? '未上传文件' : '已上传 $count 个文件');
    }
  }

  Future<void> _createFile(BuildContext context) async {
    final SessionStore store = context.sessions;
    final WorkspaceFileService service = _service(context);
    final TextEditingController controller = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('新建文件'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如 notes.md'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final String? created = await service.createFile(name.trim());
    if (!mounted) return;
    await store.refreshWorkspace();
    if (mounted) {
      showAppToast(
        this.context,
        created == null ? '创建失败：文件已存在或路径无效' : '已创建 $created',
      );
    }
  }

  Future<void> _createDirectory(BuildContext context) async {
    final SessionStore store = context.sessions;
    final WorkspaceFileService service = _service(context);
    final TextEditingController controller = TextEditingController();
    final String? name = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('新建文件夹'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '例如 assets'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || name.trim().isEmpty) return;
    final bool created = await service.createDirectory(name.trim());
    if (!mounted) return;
    await store.refreshWorkspace();
    if (mounted) {
      showAppToast(this.context, created ? '已创建文件夹 $name' : '创建文件夹失败：路径无效');
    }
  }

  Widget _buildImageGrid(BuildContext context, List<WorkspaceFile> images) {
    if (images.isEmpty) return const _EmptyHint('本次会话还没有图片');
    final List<String> gallery = images
        .map((WorkspaceFile f) => f.name)
        .toList();
    return GridView.count(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
      crossAxisCount: 2,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      childAspectRatio: 0.92,
      children: images.map((WorkspaceFile file) {
        return _ImageTile(file: file, gallery: gallery);
      }).toList(),
    );
  }

  Widget _buildFooter(BuildContext context) {
    final AppPalette palette = context.palette;
    final String path = context.sessions.workspacePathFor(
      context.sessions.active.id,
    );

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: InkWell(
        onTap: () async {
          final bool ok = await openDirectoryInExplorer(path);
          if (!context.mounted) return;
          if (!ok) {
            showAppToast(context, '无法打开目录');
          }
        },
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              Icon(Icons.folder_open_outlined, size: 15, color: palette.text2),
              const SizedBox(width: 6),
              Text(
                '打开目录',
                style: TextStyle(fontSize: 12, color: palette.text2),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FileRow extends StatelessWidget {
  const _FileRow({required this.file});

  final WorkspaceFile file;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return context_menu.ContextMenuRegion(
      actions: <context_menu.ContextAction>[
        context_menu.ContextAction(
          label: '预览',
          icon: Icons.open_in_new,
          onSelected: () => _openWorkspaceFile(context, file),
        ),
        context_menu.ContextAction(
          label: '导出',
          icon: Icons.download_outlined,
          onSelected: () => _exportWorkspaceFile(context, file),
        ),
        context_menu.ContextAction(
          label: '删除',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => _deleteWorkspaceFile(context, file),
        ),
      ],
      child: InkWell(
        onTap: () => _openWorkspaceFile(context, file),
        borderRadius: BorderRadius.circular(8),
        hoverColor: palette.hover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
          child: Row(
            children: <Widget>[
              FileIconBox(kind: file.kind, size: 26, radius: 6),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      file.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppFonts.mono(size: 11.5, color: palette.text1),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '${file.size} · ${file.time}',
                      style: TextStyle(fontSize: 10, color: palette.text3),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: '导出',
                icon: const Icon(Icons.download_outlined, size: 17),
                onPressed: () => _exportWorkspaceFile(context, file),
              ),
              IconButton(
                tooltip: '删除',
                icon: const Icon(Icons.delete_outline, size: 17),
                onPressed: () => _deleteWorkspaceFile(context, file),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

void _openWorkspaceFile(BuildContext context, WorkspaceFile file) {
  if (file.kind == FileKind.html) {
    AppNav.openHtml(context, file: file.name);
  } else {
    AppNav.openFile(context, file: file.name);
  }
}

Future<void> _exportWorkspaceFile(
  BuildContext context,
  WorkspaceFile file,
) async {
  final SessionStore store = context.sessions;
  final String root = store.workspacePathFor(store.active.id);
  final bool ok = await WorkspaceFileService(root).export(file.name);
  if (context.mounted) {
    showAppToast(context, ok ? '已导出 ${file.name}' : '导出已取消或失败');
  }
}

Future<void> _deleteWorkspaceFile(
  BuildContext context,
  WorkspaceFile file,
) async {
  final bool? confirmed = await showDialog<bool>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: const Text('删除文件？'),
      content: Text(file.name),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, true),
          child: const Text('删除'),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;
  final SessionStore store = context.sessions;
  final String root = store.workspacePathFor(store.active.id);
  final bool ok = await WorkspaceFileService(root).delete(file.name);
  if (!context.mounted) return;
  await store.refreshWorkspace();
  if (context.mounted) {
    showAppToast(context, ok ? '已删除 ${file.name}' : '删除失败');
  }
}

class _ImageTile extends StatelessWidget {
  const _ImageTile({required this.file, required this.gallery});

  final WorkspaceFile file;
  final List<String> gallery;

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return context_menu.ContextMenuRegion(
      actions: <context_menu.ContextAction>[
        context_menu.ContextAction(
          label: '查看图片',
          icon: Icons.open_in_full,
          onSelected: () =>
              AppNav.openImage(context, file: file.name, gallery: gallery),
        ),
        context_menu.ContextAction(
          label: '导出',
          icon: Icons.download_outlined,
          onSelected: () => _exportWorkspaceFile(context, file),
        ),
        context_menu.ContextAction(
          label: '删除',
          icon: Icons.delete_outline,
          destructive: true,
          onSelected: () => _deleteWorkspaceFile(context, file),
        ),
      ],
      child: InkWell(
        onTap: () =>
            AppNav.openImage(context, file: file.name, gallery: gallery),
        borderRadius: BorderRadius.circular(10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            WorkspaceImage(file: file.name, aspectRatio: 4 / 3),
            const SizedBox(height: 4),
            Text(
              file.name.split('/').last,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppFonts.mono(size: 10, color: palette.text2),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        text,
        style: TextStyle(fontSize: 11.5, color: context.palette.text3),
      ),
    );
  }
}
