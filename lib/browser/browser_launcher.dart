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
