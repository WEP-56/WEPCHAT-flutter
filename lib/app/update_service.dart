import 'dart:convert';

import 'package:http/http.dart' as http;

const String kRepositoryUrl = 'https://github.com/WEP-56/WEPCHAT-flutter';
const String kIssuesUrl = '$kRepositoryUrl/issues';
const String kLatestReleaseApi =
    'https://api.github.com/repos/WEP-56/WEPCHAT-flutter/releases/latest';

class ReleaseInfo {
  const ReleaseInfo({
    required this.version,
    required this.name,
    required this.url,
  });

  final String version;
  final String name;
  final String url;
}

class UpdateCheckResult {
  const UpdateCheckResult._({this.release, this.error});

  const UpdateCheckResult.current() : this._();

  const UpdateCheckResult.available(ReleaseInfo release)
    : this._(release: release);

  const UpdateCheckResult.failure(String error) : this._(error: error);

  final ReleaseInfo? release;
  final String? error;

  bool get hasUpdate => release != null;
}

class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  Future<UpdateCheckResult> check(String currentVersion) async {
    try {
      final http.Response response = await _client
          .get(
            Uri.parse(kLatestReleaseApi),
            headers: const <String, String>{
              'Accept': 'application/vnd.github+json',
              'User-Agent': 'WePChat',
            },
          )
          .timeout(const Duration(seconds: 8));

      if (response.statusCode != 200) {
        return UpdateCheckResult.failure(
          'GitHub 返回 HTTP ${response.statusCode}',
        );
      }

      final Object? decoded = jsonDecode(response.body);
      if (decoded is! Map<String, Object?>) {
        return const UpdateCheckResult.failure('GitHub 返回了无法识别的结果');
      }

      final String? tag = decoded['tag_name'] as String?;
      final String? url = decoded['html_url'] as String?;
      if (tag == null || url == null || tag.isEmpty || url.isEmpty) {
        return const UpdateCheckResult.failure('Release 缺少版本号或链接');
      }

      final _Version? current = _Version.tryParse(currentVersion);
      final _Version? latest = _Version.tryParse(tag);
      if (current == null || latest == null) {
        return const UpdateCheckResult.failure('无法解析 Release 版本号');
      }

      if (latest.compareTo(current) <= 0) {
        return const UpdateCheckResult.current();
      }

      return UpdateCheckResult.available(
        ReleaseInfo(
          version: tag,
          name: decoded['name'] as String? ?? tag,
          url: url,
        ),
      );
    } on Object catch (e) {
      return UpdateCheckResult.failure('检查更新失败：$e');
    }
  }

  void dispose() => _client.close();
}

class _Version implements Comparable<_Version> {
  const _Version(this.major, this.minor, this.patch);

  final int major;
  final int minor;
  final int patch;

  static _Version? tryParse(String input) {
    final RegExpMatch? match = RegExp(
      r'^\s*v?(\d+)\.(\d+)\.(\d+)(?:[-+].*)?\s*$',
    ).firstMatch(input);
    if (match == null) return null;
    return _Version(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
    );
  }

  @override
  int compareTo(_Version other) {
    final int majorResult = major.compareTo(other.major);
    if (majorResult != 0) return majorResult;
    final int minorResult = minor.compareTo(other.minor);
    if (minorResult != 0) return minorResult;
    return patch.compareTo(other.patch);
  }
}
