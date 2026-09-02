import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class BrowserHistoryItem {
  const BrowserHistoryItem({
    required this.url,
    required this.title,
    required this.visitedAt,
  });

  final String url;
  final String title;
  final DateTime visitedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'url': url,
    'title': title,
    'visitedAt': visitedAt.millisecondsSinceEpoch,
  };

  static BrowserHistoryItem? fromJson(Object? value) {
    if (value is! Map) return null;
    final String? url = value['url'] as String?;
    final int? millis = value['visitedAt'] as int?;
    if (url == null || url.isEmpty || millis == null) return null;
    return BrowserHistoryItem(
      url: url,
      title: value['title'] as String? ?? url,
      visitedAt: DateTime.fromMillisecondsSinceEpoch(millis),
    );
  }
}

class BrowserHistoryStore extends ChangeNotifier {
  BrowserHistoryStore._();

  static final BrowserHistoryStore instance = BrowserHistoryStore._();
  static const String _key = 'browser.history.v1';
  static const int _maxItems = 200;

  List<BrowserHistoryItem> _items = const <BrowserHistoryItem>[];
  SharedPreferences? _prefs;
  Future<void>? _loading;

  List<BrowserHistoryItem> get items =>
      List<BrowserHistoryItem>.unmodifiable(_items);

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    _prefs = await SharedPreferences.getInstance();
    final String? encoded = _prefs!.getString(_key);
    if (encoded == null) return;
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! List) return;
    _items = decoded
        .map(BrowserHistoryItem.fromJson)
        .whereType<BrowserHistoryItem>()
        .toList();
  }

  Future<void> record(String url, String title) async {
    await ensureLoaded();
    _items = <BrowserHistoryItem>[
      BrowserHistoryItem(
        url: url,
        title: title.isEmpty ? url : title,
        visitedAt: DateTime.now(),
      ),
      ..._items.where((BrowserHistoryItem item) => item.url != url),
    ].take(_maxItems).toList();
    await _save();
    notifyListeners();
  }

  Future<void> clear() async {
    await ensureLoaded();
    _items = const <BrowserHistoryItem>[];
    await _save();
    notifyListeners();
  }

  Future<void> _save() async {
    final SharedPreferences prefs = _prefs!;
    await prefs.setString(
      _key,
      jsonEncode(_items.map((BrowserHistoryItem e) => e.toJson()).toList()),
    );
  }
}
