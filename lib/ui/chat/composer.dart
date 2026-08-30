import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/responsive.dart';
import '../../theme/palette.dart';
import '../widgets/controls.dart';
import '../widgets/toast.dart';

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
  final ValueChanged<String> onSend;
  final VoidCallback onStop;

  @override
  State<Composer> createState() => _ComposerState();
}

class _ComposerState extends State<Composer> {
  final TextEditingController _controller = TextEditingController();
  final FocusNode _focusNode = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _submit() {
    final String text = _controller.text.trim();
    if (text.isEmpty || widget.isGenerating) return;
    _controller.clear();
    widget.onSend(text);
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (isCompact(context)) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
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
              Container(
                padding: const EdgeInsets.fromLTRB(6, 4, 6, 4),
                decoration: BoxDecoration(
                  color: palette.bgComposer,
                  border: Border.all(color: palette.border),
                  borderRadius: BorderRadius.circular(22),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    IconAction(
                      icon: Icons.attach_file,
                      tooltip: '添加附件',
                      size: 16,
                      onTap: () => showAppToast(context, '添加附件（预览版未接入文件选择）'),
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
                                final bool ready = _controller.text
                                    .trim()
                                    .isNotEmpty;
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
