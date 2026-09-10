import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'browser_page.dart';

Future<void> openWebUrl(BuildContext context, String value) async {
  final String input = value.trim();
  final String normalized = input.startsWith('www.') ? 'https://$input' : input;
  final Uri? uri = Uri.tryParse(normalized);
  if (uri == null || (uri.scheme != 'http' && uri.scheme != 'https')) return;
  if (Platform.isAndroid) {
    unawaited(
      Navigator.of(context).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => BrowserPage(url: uri.toString()),
        ),
      ),
    );
    return;
  }
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

/// 在系统浏览器里打开 OAuth 授权页。
///
/// 必须用外部用户代理，不能用应用内 WebView：规范要求由系统浏览器承接受权，
/// 多数身份提供商也会直接拒绝内嵌 WebView 发起的授权请求。
Future<bool> openAuthorizationUrl(Uri uri) =>
    launchUrl(uri, mode: LaunchMode.externalApplication);

Future<bool> openExternalScheme(String value) async {
  if (!Platform.isAndroid) {
    final Uri? uri = Uri.tryParse(value);
    return uri != null && await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
  try {
    return await const MethodChannel('com.wep.wepchat/platform').invokeMethod<bool>(
          'openExternalUrl',
          <String, Object?>{'url': value},
        ) ??
        false;
  } on Object {
    return false;
  }
}
