// ignore_for_file: curly_braces_in_flow_control_structures, use_null_aware_elements
library;

import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../../core/cancellation_token.dart';
import '../../core/errors.dart';
import '../../core/redact.dart';
import '../../ai/provider_headers.dart';

class OpenAiImageResult {
  const OpenAiImageResult(this.images);
  final List<List<int>> images;
}

class OpenAiImageClient {
  OpenAiImageClient({
    required this.apiKey,
    required this.baseUrl,
    this.customHeaders = const <String, String>{},
  });
  final String apiKey;
  final String baseUrl;
  final Map<String, String> customHeaders;

  Future<OpenAiImageResult> generate({
    required String model,
    required String prompt,
    String? size,
    int count = 1,
    required CancellationToken token,
  }) async {
    final Map<String, Object?> body = <String, Object?>{
      'model': model,
      'prompt': prompt,
      'n': count,
      if (size != null) 'size': size,
      'response_format': 'b64_json',
    };
    final Object? json = await _postJson('/images/generations', body, token);
    return _decode(json);
  }

  Future<OpenAiImageResult> edit({
    required String model,
    required File image,
    required String prompt,
    String? size,
    required CancellationToken token,
  }) async {
    final http.Client client = http.Client();
    token.onCancel(client.close);
    try {
      token.throwIfCancelled();
      final http.MultipartRequest request =
          http.MultipartRequest(
              'POST',
              Uri.parse('${_trim(baseUrl)}/images/edits'),
            )
            ..headers.addAll(
              buildProviderHeaders(
                defaults: <String, String>{'authorization': 'Bearer $apiKey'},
                custom: customHeaders,
              ),
            )
            ..fields['model'] = model
            ..fields['prompt'] = prompt
            ..fields['response_format'] = 'b64_json';
      if (size != null) request.fields['size'] = size;
      request.files.add(await http.MultipartFile.fromPath('image', image.path));
      final http.StreamedResponse response = await client.send(request);
      final List<int> bytes = await response.stream.toBytes();
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw ApiError(
          '图片编辑 API 返回错误',
          statusCode: response.statusCode,
          providerMessage: redact(_error(bytes)),
        );
      return _decode(jsonDecode(utf8.decode(bytes)));
    } on CancelledException {
      rethrow;
    } on WepError {
      rethrow;
    } on Object catch (e) {
      throw NetworkError(
        '图片编辑请求失败',
        context: <String, Object?>{'cause': redact(e.toString())},
      );
    } finally {
      client.close();
    }
  }

  Future<Object?> _postJson(
    String path,
    Map<String, Object?> body,
    CancellationToken token,
  ) async {
    final http.Client client = http.Client();
    token.onCancel(client.close);
    try {
      token.throwIfCancelled();
      final http.Response response = await client.post(
        Uri.parse('${_trim(baseUrl)}$path'),
        headers: buildProviderHeaders(
          defaults: <String, String>{
            'authorization': 'Bearer $apiKey',
            'content-type': 'application/json',
          },
          custom: customHeaders,
        ),
        body: jsonEncode(body),
      );
      if (response.statusCode < 200 || response.statusCode >= 300)
        throw ApiError(
          '图片生成 API 返回错误',
          statusCode: response.statusCode,
          providerMessage: redact(_error(utf8.encode(response.body))),
        );
      return jsonDecode(response.body);
    } on CancelledException {
      rethrow;
    } on WepError {
      rethrow;
    } on FormatException {
      throw ApiError('图片 API 返回了无效 JSON', statusCode: 200);
    } on Object catch (e) {
      throw NetworkError(
        '图片生成请求失败',
        context: <String, Object?>{'cause': redact(e.toString())},
      );
    } finally {
      client.close();
    }
  }

  OpenAiImageResult _decode(Object? raw) {
    if (raw is! Map<String, Object?> || raw['data'] is! List)
      throw ApiError('图片 API 返回中没有图像数据', statusCode: 200);
    final List<List<int>> out = <List<int>>[];
    for (final Object? item in raw['data'] as List<Object?>) {
      if (item is Map<String, Object?> && item['b64_json'] is String)
        out.add(base64Decode(item['b64_json'] as String));
    }
    if (out.isEmpty) {
      throw ApiError('图片 API 返回中没有可解码的图像', statusCode: 200);
    }
    return OpenAiImageResult(out);
  }
}

String _trim(String value) {
  var out = value;
  while (out.endsWith('/')) out = out.substring(0, out.length - 1);
  return out;
}

String _error(List<int> bytes) => utf8
    .decode(bytes, allowMalformed: true)
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
