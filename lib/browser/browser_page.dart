import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'browser_downloads.dart';
import 'browser_history.dart';

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
    body: InAppWebView(
      initialSettings: _settings,
      initialFile: widget.filePath,
      initialUrlRequest: widget.url == null
          ? null
          : URLRequest(url: WebUri(widget.url!)),
      onWebViewCreated: (controller) => _controller = controller,
      onLoadStart: (controller, url) {
        if (mounted) setState(() => _url = url?.toString() ?? '');
      },
      onProgressChanged: (controller, progress) {
        if (mounted) setState(() => _progress = progress);
      },
      onTitleChanged: (controller, title) {
        if (mounted && title != null) setState(() => _title = title);
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
        if (current.startsWith('http://') || current.startsWith('https://')) {
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
  );
}
