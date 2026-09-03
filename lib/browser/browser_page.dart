import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'browser_downloads.dart';
import 'browser_history.dart';

/// InAppWebView 的 `initialFile` 只接受 Flutter asset 路径。工作区文件必须
/// 转成 file URI 后作为普通导航请求加载，否则 Android 会把绝对路径拼到
/// `flutter_assets/` 下并得到白屏。
Uri browserFileUri(String path, {bool? windows}) {
  if (path.trim().isEmpty) {
    throw ArgumentError.value(path, 'path', '文件路径不能为空');
  }
  return Uri.file(path, windows: windows ?? Platform.isWindows);
}

class BrowserPage extends StatefulWidget {
  const BrowserPage({super.key, this.url, this.filePath})
    : assert(url != null || filePath != null);
  final String? url;
  final String? filePath;
  @override
  State<BrowserPage> createState() => _BrowserPageState();
}

class _BrowserPageState extends State<BrowserPage> {
  InAppWebViewController? _controller;
  String _url = '';
  String _title = '';
  String? _loadError;
  int _progress = 0;
  bool _canGoBack = false;
  bool _canGoForward = false;

  InAppWebViewSettings get _settings => InAppWebViewSettings(
    javaScriptEnabled: true,
    domStorageEnabled: true,
    cacheEnabled: true,
    sharedCookiesEnabled: true,
    thirdPartyCookiesEnabled: true,
    useShouldOverrideUrlLoading: true,
    useOnDownloadStart: true,
    allowFileAccessFromFileURLs: true,
    allowUniversalAccessFromFileURLs: true,
  );

  URLRequest get _initialRequest {
    final String? url = widget.url;
    if (url != null) return URLRequest(url: WebUri(url));
    return URLRequest(url: WebUri(browserFileUri(widget.filePath!).toString()));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        _title.isEmpty ? _url : _title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => Navigator.pop(context),
      ),
      actions: <Widget>[
        IconButton(
          onPressed: _canGoBack ? () => _controller?.goBack() : null,
          icon: const Icon(Icons.arrow_back),
        ),
        IconButton(
          onPressed: _canGoForward ? () => _controller?.goForward() : null,
          icon: const Icon(Icons.arrow_forward),
        ),
        IconButton(
          onPressed: () => _controller?.reload(),
          icon: const Icon(Icons.refresh),
        ),
      ],
      bottom: _progress < 100
          ? PreferredSize(
              preferredSize: const Size.fromHeight(2),
              child: LinearProgressIndicator(value: _progress / 100),
            )
          : null,
    ),
    body: Stack(
      children: <Widget>[
        InAppWebView(
          initialSettings: _settings,
          initialUrlRequest: _initialRequest,
          onWebViewCreated: (controller) => _controller = controller,
          onLoadStart: (controller, url) {
            if (!mounted) return;
            setState(() {
              _url = url?.toString() ?? '';
              _loadError = null;
            });
          },
          onProgressChanged: (controller, progress) {
            if (mounted) setState(() => _progress = progress);
          },
          onTitleChanged: (controller, title) {
            if (mounted && title != null) setState(() => _title = title);
          },
          onReceivedError: (controller, request, error) {
            if (!mounted || request.isForMainFrame != true) return;
            setState(() => _loadError = error.description);
          },
          onLoadStop: (controller, url) async {
            final bool back = await controller.canGoBack();
            final bool forward = await controller.canGoForward();
            if (!mounted) return;
            setState(() {
              _url = url?.toString() ?? _url;
              _canGoBack = back;
              _canGoForward = forward;
            });
            final String current = url?.toString() ?? '';
            if (current.startsWith('http://') ||
                current.startsWith('https://')) {
              unawaited(BrowserHistoryStore.instance.record(current, _title));
            }
          },
          onDownloadStartRequest: (controller, request) => unawaited(
            BrowserDownloadStore.instance.start(
              request.url.toString(),
              suggestedFilename: request.suggestedFilename,
              contentDisposition: request.contentDisposition,
              mimeType: request.mimeType,
            ),
          ),
          shouldOverrideUrlLoading: (controller, action) async {
            final WebUri? target = action.request.url;
            if (target == null) return NavigationActionPolicy.CANCEL;
            const allowed = <String>{
              'http',
              'https',
              'file',
              'about',
              'data',
              'blob',
            };
            return allowed.contains(target.scheme.toLowerCase())
                ? NavigationActionPolicy.ALLOW
                : NavigationActionPolicy.CANCEL;
          },
        ),
        if (_loadError != null)
          ColoredBox(
            color: Theme.of(context).colorScheme.surface,
            child: Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const Icon(Icons.error_outline, size: 32),
                    const SizedBox(height: 12),
                    Text('页面加载失败：$_loadError', textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () {
                        setState(() => _loadError = null);
                        _controller?.reload();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}
