import 'dart:io' show Platform;

import 'package:url_launcher/url_launcher.dart';

import '../config.dart';
import 'diag.dart';

/// Feature 5 — push-to-talk with dispatch via Mumble/Mumla.
///
/// Per the companion design (decision K8), the default integration is a
/// deep-link into the dedicated Mumble client rather than an embedded VoIP
/// stack: it's reliable, keeps radio audio in a purpose-built app, and needs no
/// custom Murmur admin plumbing. Mumla (Android) and Mumble register the
/// `mumble://` scheme, so we can hand it the NAS tailnet address directly.
class MumbleRadio {
  /// `mumble://<user>@<host>:<port>/` — Mumla parses user/host/port from this.
  static Uri connectUri({String? username}) {
    final user = (username == null || username.isEmpty) ? '' : '${Uri.encodeComponent(username)}@';
    return Uri.parse('mumble://$user${AppConfig.mumbleHost}:${AppConfig.mumblePort}/');
  }

  /// Try to open the radio in Mumla/Mumble. Returns false if no client handled
  /// the scheme (i.e. the app isn't installed).
  static Future<bool> openRadio({String? username}) async {
    final uri = connectUri(username: username);
    try {
      if (await canLaunchUrl(uri)) {
        return await launchUrl(uri, mode: LaunchMode.externalApplication);
      }
    } catch (e) {
      Diag.log('radio: mumble launch failed: $e');
    }
    return false;
  }

  /// Send the driver to install Mumla (Android) / Mumble (iOS) when it's missing.
  static Future<void> openStore() async {
    final uri = Platform.isIOS
        ? Uri.parse('https://apps.apple.com/app/mumble/id443472808')
        : Uri.parse('https://play.google.com/store/apps/details?id=se.lublin.mumla');
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }
}
