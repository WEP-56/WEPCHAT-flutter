import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import '../../browser/browser_page.dart';
import '../../theme/palette.dart';

enum _ViewMode { preview, source }

/// HTML 文件全屏查看器：预览 + 源码。
///
/// Android、Windows 统一使用此界面，支持预览与源码双模式切换。
class HtmlViewerScreen extends StatefulWidget {
  const HtmlViewerScreen({super.key, required this.filePath});

  /// 已验证的工作区文件绝对路径。
  final String filePath;

  @override
  State<HtmlViewerScreen> createState() => _HtmlViewerScreenState();
}

class _HtmlViewerScreenState extends State<HtmlViewerScreen> {
  _ViewMode _mode = _ViewMode.preview;
  InAppWebViewController? _controller;
  String? _sourceCode;
  bool _loadingSource = false;
  String? _loadError;
  int _progress = 0;

  String get _fileName => widget.filePath.split(Platform.pathSeparator).last;

  @override
  void initState() {
    super.initState();
    // 预加载源码，以便快速切换
    _loadSource();
  }

  Future<void> _loadSource() async {
    setState(() => _loadingSource = true);
    try {
      final File file = File(widget.filePath);
      final String content = await file.readAsString();
      if (mounted) {
        setState(() {
          _sourceCode = content;
          _loadingSource = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _sourceCode = '读取失败：$e';
          _loadingSource = false;
        });
      }
    }
  }

  InAppWebViewSettings get _settings => InAppWebViewSettings(
        javaScriptEnabled: true,
        domStorageEnabled: true,
        cacheEnabled: true,
        allowFileAccessFromFileURLs: true,
        allowUniversalAccessFromFileURLs: true,
      );

  @override
  Widget build(BuildContext context) {
    final AppPalette palette = context.palette;
    return Scaffold(
      backgroundColor: palette.bg,
      appBar: AppBar(
        backgroundColor: palette.bgSide,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.close),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          _fileName,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 14, color: palette.text1),
        ),
        actions: <Widget>[
          // 预览/源码切换
          SegmentedButton<_ViewMode>(
            selected: <_ViewMode>{_mode},
            onSelectionChanged: (Set<_ViewMode> selected) {
              setState(() => _mode = selected.first);
            },
            segments: const <ButtonSegment<_ViewMode>>[
              ButtonSegment<_ViewMode>(
                value: _ViewMode.preview,
                label: Text('预览', style: TextStyle(fontSize: 12)),
                icon: Icon(Icons.visibility_outlined, size: 16),
              ),
              ButtonSegment<_ViewMode>(
                value: _ViewMode.source,
                label: Text('源码', style: TextStyle(fontSize: 12)),
                icon: Icon(Icons.code, size: 16),
              ),
            ],
          ),
          const SizedBox(width: 4),
          if (_mode == _ViewMode.preview) ...<Widget>[
            IconButton(
              onPressed: () => _controller?.reload(),
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: '刷新',
            ),
          ] else ...<Widget>[
            IconButton(
              onPressed: _sourceCode != null
                  ? () {
                      Clipboard.setData(ClipboardData(text: _sourceCode!));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('已复制源码'),
                          duration: Duration(seconds: 1),
                        ),
                      );
                    }
                  : null,
              icon: const Icon(Icons.copy, size: 20),
              tooltip: '复制源码',
            ),
          ],
          const SizedBox(width: 8),
        ],
        bottom: _mode == _ViewMode.preview && _progress < 100
            ? PreferredSize(
                preferredSize: const Size.fromHeight(2),
                child: LinearProgressIndicator(value: _progress / 100),
              )
            : null,
      ),
      body: switch (_mode) {
        _ViewMode.preview => _buildPreview(palette),
        _ViewMode.source => _buildSource(palette),
      },
    );
  }

  Widget _buildPreview(AppPalette palette) {
    return Stack(
      children: <Widget>[
        InAppWebView(
          initialSettings: _settings,
          initialUrlRequest: URLRequest(
            url: WebUri(browserFileUri(widget.filePath).toString()),
          ),
          onWebViewCreated: (InAppWebViewController controller) {
            _controller = controller;
          },
          onLoadStart: (InAppWebViewController controller, WebUri? url) {
            if (mounted) {
              setState(() => _loadError = null);
            }
          },
          onProgressChanged: (InAppWebViewController controller, int progress) {
            if (mounted) {
              setState(() => _progress = progress);
            }
          },
          onReceivedError: (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) {
            if (!mounted || request.isForMainFrame != true) return;
            setState(() => _loadError = error.description);
          },
          onLoadStop: (InAppWebViewController controller, WebUri? url) {
            if (mounted) {
              setState(() => _progress = 100);
            }
          },
        ),
        if (_loadError != null)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Icon(Icons.error_outline, size: 48, color: palette.text3),
                  const SizedBox(height: 16),
                  Text(
                    '加载失败',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: palette.text1,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _loadError!,
                    style: TextStyle(fontSize: 13, color: palette.text2),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSource(AppPalette palette) {
    if (_loadingSource) {
      return const Center(child: CircularProgressIndicator());
    }

    final String? source = _sourceCode;
    if (source == null) {
      return Center(
        child: Text(
          '源码加载中...',
          style: TextStyle(fontSize: 13, color: palette.text3),
        ),
      );
    }

    return SelectionArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Text(
          source,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: 12,
            color: palette.text1,
            height: 1.5,
          ),
        ),
      ),
    );
  }
}
