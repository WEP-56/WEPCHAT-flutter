import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../ai/provider_config.dart';
import '../ai/model_catalog.dart';
import '../state/app_settings.dart';
import '../models/settings.dart';
import '../storage/storage.dart';
import '../core/ulid.dart';
import 'zip_archive.dart';

class WebDavConfig {
  const WebDavConfig({
    required this.url,
    required this.username,
    required this.password,
  });
  final String url;
  final String username;
  final String password;
}

class WebDavBackupService {
  WebDavBackupService({http.Client? client})
    : _client = client ?? http.Client();
  final http.Client _client;

  Future<void> test(WebDavConfig config) async {
    final request = http.Request('PROPFIND', _uri(config, ''))
      ..headers.addAll(
        _headers(config, depth: '0', contentType: 'application/xml'),
      )
      ..body =
          '<?xml version="1.0"?><propfind xmlns="DAV:"><prop><resourcetype/></prop></propfind>';
    final response = await _client.send(request);
    if (response.statusCode < 200 || response.statusCode >= 400) {
      throw Exception('WebDAV 连接失败（HTTP ${response.statusCode}）');
    }
  }

  Future<void> upload(
    WebDavConfig config,
    Uint8List bytes, {
    String filename = 'wepchat-backup.wepchat',
  }) async {
    final response = await _client.put(
      _uri(config, filename),
      headers: _headers(config, contentType: 'application/zip'),
      body: bytes,
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('WebDAV 上传失败（HTTP ${response.statusCode}）');
    }
  }

  Future<Uint8List> download(WebDavConfig config, String filename) async {
    final response = await _client.get(
      _uri(config, filename),
      headers: _headers(config),
    );
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('WebDAV 下载失败（HTTP ${response.statusCode}）');
    }
    return response.bodyBytes;
  }

  Future<Uint8List> buildBackup({
    required AppSettings settings,
    required WepStorage storage,
  }) async {
    final ZipArchive zip = ZipArchive();
    zip.addText(
      'manifest.json',
      jsonEncode(<String, Object?>{'format': 'wepchat-backup', 'version': 1}),
    );
    zip.addText(
      'settings.json',
      jsonEncode(<String, Object?>{
        'providers': [
          for (final ProviderConfig p in settings.providers) p.toJson(),
        ],
        'models': [for (final ModelSpec m in settings.models) m.toJson()],
        'defaultModelKey': settings.defaultModelKey,
        'imageGenModelKey': settings.imageGenModelKey,
        'imageEditModelKey': settings.imageEditModelKey,
        'searchBackendId': settings.searchBackendId,
        'searchProviders': [
          for (final SearchProviderConfig p in settings.searchProviders)
            p.toJson(),
        ],
      }),
    );
    final List<SessionSummary> sessions = await storage.listSessions(
      limit: 1000,
    );
    final List<Map<String, Object?>> exported = <Map<String, Object?>>[];
    for (final SessionSummary summary in sessions) {
      final SessionRecord? record = await storage.findSession(summary.id);
      if (record == null) continue;
      final List<EntryRecord> entries = await storage.readContext(summary.id);
      exported.add(<String, Object?>{
        'id': record.id,
        'title': record.title,
        'createdAt': record.createdAt.toIso8601String(),
        'updatedAt': record.updatedAt.toIso8601String(),
        'providerId': record.providerId,
        'modelId': record.modelId,
        'thinking': record.thinking.wire,
        'entries': [
          for (final EntryRecord e in entries)
            <String, Object?>{
              'id': e.id,
              'type': e.type.wire,
              'role': e.role?.wire,
              'createdAt': e.createdAt.toIso8601String(),
              'payload': e.payload,
            },
        ],
      });
    }
    zip.addText('sessions.json', jsonEncode(exported));
    final List<MemorySummary> memories = await storage.listMemories();
    final List<Map<String, Object?>> memoryData = <Map<String, Object?>>[];
    for (final MemorySummary summary in memories) {
      final MemoryRecord? memory = await storage.readMemory(summary.id);
      if (memory == null) continue;
      memoryData.add(<String, Object?>{
        'id': memory.id,
        'category': memory.category,
        'key': memory.key,
        'content': memory.content,
        'tags': memory.tags,
        'createdAt': memory.createdAt.toIso8601String(),
        'updatedAt': memory.updatedAt.toIso8601String(),
      });
    }
    zip.addText('memories.json', jsonEncode(memoryData));
    return zip.build();
  }

  Future<void> restore({
    required WebDavConfig config,
    required AppSettings settings,
    required WepStorage storage,
    String filename = 'wepchat-backup.wepchat',
  }) async {
    final Map<String, Uint8List> files = ZipArchive.extract(
      await download(config, filename),
    );
    final Object? manifest = files['manifest.json'] == null
        ? null
        : jsonDecode(utf8.decode(files['manifest.json']!));
    if (manifest is! Map || manifest['format'] != 'wepchat-backup')
      throw const FormatException('不是有效的 WePChat 备份包');
    final Object? settingsRaw = files['settings.json'] == null
        ? null
        : jsonDecode(utf8.decode(files['settings.json']!));
    if (settingsRaw is! Map) throw const FormatException('备份缺少设置数据');
    await settings.importPortableConfig(Map<String, Object?>.from(settingsRaw));
    final Object? memoriesRaw = files['memories.json'] == null
        ? null
        : jsonDecode(utf8.decode(files['memories.json']!));
    if (memoriesRaw is List) {
      for (final Object? raw in memoriesRaw) {
        if (raw is! Map) continue;
        await storage.saveMemory(
          MemoryRecord(
            id: raw['id'] as String? ?? '',
            category: raw['category'] as String? ?? 'volatile',
            key: raw['key'] as String? ?? '',
            content: raw['content'] as String? ?? '',
            tags: raw['tags'] as String?,
            createdAt:
                DateTime.tryParse(raw['createdAt'] as String? ?? '') ??
                DateTime.now(),
            updatedAt:
                DateTime.tryParse(raw['updatedAt'] as String? ?? '') ??
                DateTime.now(),
          ),
        );
      }
    }
    final Object? sessionsRaw = files['sessions.json'] == null
        ? null
        : jsonDecode(utf8.decode(files['sessions.json']!));
    if (sessionsRaw is List) {
      for (final Object? raw in sessionsRaw) {
        if (raw is! Map) continue;
        final SessionRecord created = await storage.createSession(
          title: raw['title'] as String? ?? '恢复的会话',
          workspaceRoot: settings.workspaceRoot,
          providerId: raw['providerId'] as String? ?? '',
          modelId: raw['modelId'] as String? ?? '',
        );
        final Object? entries = raw['entries'];
        if (entries is! List) continue;
        for (final Object? entry in entries) {
          if (entry is! Map || entry['type'] != 'message') continue;
          final Object? payload = entry['payload'];
          if (payload is! Map) continue;
          await storage.appendEntry(
            created.id,
            NewEntry(
              id: entry['id'] as String? ?? Ulid.generate(),
              type: EntryType.message,
              role: EntryRole.fromWire(entry['role'] as String? ?? 'user'),
              payload: Map<String, Object?>.from(payload),
            ),
          );
        }
      }
    }
  }

  Uri _uri(WebDavConfig config, String filename) {
    final Uri base = Uri.parse(
      config.url.endsWith('/') ? config.url : '${config.url}/',
    );
    return base.resolve(Uri.encodeComponent(filename));
  }

  Map<String, String> _headers(
    WebDavConfig config, {
    String? depth,
    String? contentType,
  }) {
    final String auth = base64Encode(
      utf8.encode('${config.username}:${config.password}'),
    );
    return <String, String>{
      'Authorization': 'Basic $auth',
      if (depth != null) 'Depth': depth,
      if (contentType != null) 'Content-Type': contentType,
    };
  }

  void close() => _client.close();
}
