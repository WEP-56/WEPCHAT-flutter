// ignore_for_file: curly_braces_in_flow_control_structures
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/cancellation_token.dart';
import '../../core/errors.dart';
import '../../core/redact.dart';

class WebResponse {
  const WebResponse({
    required this.statusCode,
    required this.headers,
    required this.bytes,
  });
  final int statusCode;
  final Map<String, String> headers;
  final List<int> bytes;
  String get text => utf8.decode(bytes, allowMalformed: true);
}

Future<WebResponse> webRequest({
  required String method,
  required Uri url,
  Map<String, String> headers = const <String, String>{},
  List<int>? body,
  required CancellationToken token,
}) async {
  final http.Client client = http.Client();
  token.onCancel(client.close);
  try {
    token.throwIfCancelled();
    final http.Request request = http.Request(method, url)
      ..headers.addAll(headers)
      ..bodyBytes = body ?? const <int>[];
    final http.StreamedResponse response = await client.send(request);
    final List<int> bytes = await response.stream.toBytes();
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw ApiError(
        '网络服务返回错误',
        statusCode: response.statusCode,
        providerMessage: redact(_errorText(bytes)),
      );
    }
    return WebResponse(
      statusCode: response.statusCode,
      headers: response.headers,
      bytes: bytes,
    );
  } on CancelledException {
    rethrow;
  } on WepError {
    rethrow;
  } on Object catch (e) {
    throw NetworkError(
      '网络请求失败',
      context: <String, Object?>{
        'host': url.host,
        'cause': redact(e.toString()),
      },
    );
  } finally {
    client.close();
  }
}

String _errorText(List<int> bytes) {
  final String raw = utf8.decode(bytes, allowMalformed: true);
  try {
    final Object? value = jsonDecode(raw);
    if (value is Map<String, Object?>) {
      final Object? error = value['error'];
      if (error is Map<String, Object?> && error['message'] is String)
        return error['message'] as String;
      if (error is String) return error;
    }
  } on FormatException {
    /* use raw */
  }
  return raw.length > 500 ? '${raw.substring(0, 500)}…' : raw;
}
