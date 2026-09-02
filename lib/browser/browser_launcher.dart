import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
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
