import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BrowserDownloadItem {
  const BrowserDownloadItem({
    required this.url,
    required this.filename,
    required this.status,
  });

  final String url;
  final String filename;
  final String status;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'filename': filename,
    'status': status,
  };

  static BrowserDownloadItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final String? url = value['url'] as String?;
    final String? filename = value['filename'] as String?;
    if (url == null || filename == null) return null;
    return BrowserDownloadItem(
      url: url,
      filename: filename,
      status: value['status'] as String? ?? 'done',
    );
  }
}

class BrowserDownloadStore extends ChangeNotifier {
  BrowserDownloadStore._();

  static final BrowserDownloadStore instance = BrowserDownloadStore._();
  static const String _key = 'browser.downloads.v1';

  List<BrowserDownloadItem> _items = const <BrowserDownloadItem>[];
  SharedPreferences? _prefs;
  Future<void>? _loading;

  List<BrowserDownloadItem> get items =>
      List<BrowserDownloadItem>.unmodifiable(_items);

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    final String? encoded = _prefs!.getString(_key);
    if (encoded == null) return;
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! List) return;
    _items = decoded
        .map(BrowserDownloadItem.fromJson)
        .whereType<BrowserDownloadItem>()
        .toList();
  }

  Future<void> start(
    String url, {
    String? suggestedFilename,
    String? contentDisposition,
    String? mimeType,
  }) async {
    await ensureLoaded();
    final String filename = _safeFilename(
      suggestedFilename ?? _filenameFromDisposition(contentDisposition),
      url,
    );
    _items = <BrowserDownloadItem>[
      BrowserDownloadItem(url: url, filename: filename, status: 'downloading'),
      ..._items,
    ];
    notifyListeners();
    final http.Client client = http.Client();
    try {
      final Directory dir = Directory(
        p.join((await getApplicationDocumentsDirectory()).path, 'downloads'),
      );
      await dir.create(recursive: true);
      final http.StreamedResponse response = await client.send(
        http.Request('GET', Uri.parse(url)),
      );
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException('HTTP ${response.statusCode}', uri: Uri.parse(url));
      }
      final File target = File(p.join(dir.path, filename));
      await response.stream.pipe(target.openWrite());
      _replace(
        url,
        BrowserDownloadItem(url: url, filename: filename, status: 'done'),
      );
    } on Object {
      _replace(
        url,
        BrowserDownloadItem(url: url, filename: filename, status: 'failed'),
      );
    } finally {
      client.close();
    }
    await _save();
    notifyListeners();
  }

  void _replace(String url, BrowserDownloadItem replacement) {
    _items = <BrowserDownloadItem>[
      replacement,
      ..._items.where((BrowserDownloadItem e) => e.url != url),
    ];
  }

  Future<void> clear() async {
    await ensureLoaded();
    _items = const <BrowserDownloadItem>[];
    await _save();
    notifyListeners();
  }

  String _safeFilename(String? suggested, String url) {
    final String raw = (suggested ?? p.basename(Uri.tryParse(url)?.path ?? ''))
        .trim();
    final String value = raw.isEmpty
        ? 'download-${DateTime.now().millisecondsSinceEpoch}'
        : raw;
    return value.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  String? _filenameFromDisposition(String? disposition) {
    if (disposition == null) return null;
    final RegExpMatch? match = RegExp(
      r'filename="?([^";]+)',
    ).firstMatch(disposition);
    return match?.group(1)?.trim();
  }

  Future<void> _save() async {
    await _prefs!.setString(
      _key,
      jsonEncode(_items.map((BrowserDownloadItem e) => e.toJson()).toList()),
    );
  }
}
