import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
// ignore_for_file: sort_child_properties_last
import 'package:file_selector/file_selector.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:super_clipboard/super_clipboard.dart';

import '../../app/responsive.dart';
import '../../theme/palette.dart';
import '../../models/chat.dart';
import '../widgets/controls.dart';

/// 输入区。桌面端 Enter 发送、Shift+Enter 换行；窄屏 Enter 始终换行，
/// 由右侧按钮发送。
class Composer extends StatefulWidget {
  const Composer({
    super.key,
    required this.isGenerating,
    required this.onSend,
    required this.onStop,
  });

  final bool isGenerating;
  final void Function(String text, List<PendingAttachment> attachments) onSend;
  final VoidCallback onStop;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();
  final List<PendingAttachment> _attachments = <PendingAttachment>[];
  bool _dragging = false;

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final String text = _controller.text.trim();
    if ((text.isEmpty && _attachments.isEmpty) || widget.isGenerating) return;
    _controller.clear();
    widget.onSend(text, List<PendingAttachment>.unmodifiable(_attachments));
    setState(_attachments.clear);
  }

  Future<void> _pickFiles() async {
    final List<XFile> files = await openFiles(
      acceptedTypeGroups: <XTypeGroup>[
        XTypeGroup(
          label: '图片与文档',
          extensions: <String>[
            'png',
            'jpg',
            'jpeg',
            'gif',
            'webp',
            'pdf',
            'txt',
            'md',
            'csv',
            'json',
          ],
        ),
      ],
    );
    await _addFiles(files);
  }

  Future<void> _addFiles(Iterable<XFile> files) async {
    final List<PendingAttachment> added = <PendingAttachment>[];
    for (final XFile file in files.take(8)) {
      final Uint8List bytes = await file.readAsBytes();
      if (bytes.length > 20 * 1024 * 1024) continue;
      added.add(
        PendingAttachment(
          name: file.name,
          mimeType: _mime(file.name),
          bytes: bytes,
        ),
      );
    }
    if (added.isNotEmpty && mounted) setState(() => _attachments.addAll(added));
  }

  Future<void> _pasteClipboard() async {
    final clipboard = SystemClipboard.instance;
    if (clipboard == null) return;
    final reader = await clipboard.read();
    if (reader.canProvide(Formats.png)) {
      reader.getFile(Formats.png, (file) async {
        final List<int> bytes = <int>[];
        await for (final List<int> chunk in file.getStream()) {
          bytes.addAll(chunk);
          if (bytes.length > 20 * 1024 * 1024) return;
        }
        if (!mounted) return;
        setState(
          () => _attachments.add(
            PendingAttachment(
              name: 'pasted-image.png',
              mimeType: 'image/png',
              bytes: Uint8List.fromList(bytes),
            ),
          ),
        );
      });
      return;
    }

    // 没有图片时保持 Ctrl/⌘+V 的普通文本语义，在当前选区插入文本。
    if (!reader.canProvide(Formats.plainText)) return;
    final String? text = await reader.readValue(Formats.plainText);
    if (text == null || text.isEmpty || !mounted) return;
    final TextSelection selection = _controller.selection;
    final int start = selection.isValid
        ? selection.start
        : _controller.text.length;
    final int end = selection.isValid ? selection.end : start;
    _controller.value = _controller.value.copyWith(
      text: _controller.text.replaceRange(start, end, text),
      selection: TextSelection.collapsed(offset: start + text.length),
      composing: TextRange.empty,
    );
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isCompact(context)) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    if (event.logicalKey == LogicalKeyboardKey.keyV &&
        (HardwareKeyboard.instance.isControlPressed ||
            HardwareKeyboard.instance.isMetaPressed)) {
      unawaited(_pasteClipboard());
      return KeyEventResult.handled;
    }
    if (event.logicalKey != LogicalKeyboardKey.enter) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isShiftPressed) {
      return KeyEventResult.ignored;
    }
    _submit();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    final bool compact = isCompact(context);

    return Container(
      padding: EdgeInsets.fromLTRB(compact ? 12 : 20, 8, compact ? 12 : 20, 12),
      color: palette.bg,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              DropTarget(
                onDragEntered: (_) => setState(() => _dragging = true),
                onDragExited: (_) => setState(() => _dragging = false),
                onDragDone: (DropDoneDetails detail) async {
                  setState(() => _dragging = false);
                  await _addFiles(detail.files);
                },
                child: Container(
                  padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      IconAction(
                        icon: Icons.attach_file,
                        tooltip: '添加附件',
                        size: 16,
                        onTap: _pickFiles,
                      ),
                      Expanded(
                        child: Focus(
                          onKeyEvent: _onKey,
                          child: TextField(
                            controller: _controller,
                            focusNode: _focusNode,
                            minLines: 1,
                            maxLines: 6,
                            keyboardType: TextInputType.multiline,
                            textInputAction: TextInputAction.newline,
                            style: TextStyle(
                              fontSize: 13.5,
                              color: palette.text1,
                            ),
                            cursorColor: palette.accent,
                            decoration: InputDecoration(
                              isDense: true,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              filled: false,
                              hintText: '给 WePChat 发消息…',
                              hintStyle: TextStyle(
                                fontSize: 13.5,
                                color: palette.text3,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 4,
                                vertical: 8,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2),
                        child: widget.isGenerating
                            ? _RoundButton(
                                icon: Icons.stop,
                                tooltip: '停止生成',
                                background: palette.bgRaise2,
                                foreground: palette.text1,
                                onTap: widget.onStop,
                              )
                            : ListenableBuilder(
                                listenable: _controller,
                                builder: (BuildContext context, Widget? _) {
                                  final bool ready =
                                      _controller.text.trim().isNotEmpty ||
                                      _attachments.isNotEmpty;
                                  return _RoundButton(
                                    icon: Icons.arrow_upward,
                                    tooltip: '发送',
                                    background: ready
                                        ? palette.accent
                                        : palette.bgRaise2,
                                    foreground: ready
                                        ? Colors.white
                                        : palette.text3,
                                    onTap: ready ? _submit : null,
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                  decoration: BoxDecoration(
                    color: _dragging ? palette.bgRaise2 : palette.bgComposer,
                    border: Border.all(
                      color: _dragging ? palette.accent : palette.border,
                    ),
                    borderRadius: BorderRadius.circular(22),
                  ),
                ),
              ),
              if (_attachments.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: <Widget>[
                      for (int i = 0; i < _attachments.length; i++)
                        Chip(
                          label: Text(
                            _attachments[i].name,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onDeleted: () =>
                              setState(() => _attachments.removeAt(i)),
                        ),
                    ],
                  ),
                ),
              if (!compact)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    'Enter 发送 · Shift+Enter 换行 · 内容由模型生成，请自行核对',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 10.5, color: palette.text3),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

String _mime(String name) {
  final String ext = name.split('.').last.toLowerCase();
  return <String, String>{
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'webp': 'image/webp',
        'pdf': 'application/pdf',
        'json': 'application/json',
        'csv': 'text/csv',
        'md': 'text/markdown',
        'txt': 'text/plain',
      }[ext] ??
      'application/octet-stream';
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({
    required this.icon,
    required this.tooltip,
    required this.background,
    required this.foreground,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final Color background;
  final Color foreground;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(color: background, shape: BoxShape.circle),
          child: Center(child: Icon(icon, size: 17, color: foreground)),
        ),
      ),
    );
  }
}
