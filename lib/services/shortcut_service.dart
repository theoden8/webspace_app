import 'dart:io';
import 'package:flutter/services.dart';

class ShortcutService {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  /// Request a pinned home screen shortcut for a site (Android only).
  /// Returns true if the request was made successfully.
  static Future<bool> pinShortcut({
    required String siteId,
    required String label,
    String? iconUrl,
  }) async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _channel.invokeMethod('pinShortcut', {
        'siteId': siteId,
        'label': label,
        'iconUrl': iconUrl,
      });
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  /// Remove a pinned shortcut when a site is deleted (Android only).
  static Future<void> removeShortcut(String siteId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('removeShortcut', {'siteId': siteId});
    } on PlatformException {
      // Ignore — shortcut may not exist
    }
  }

  /// Get the siteId from the launch intent (if app was opened via shortcut).
  static Future<String?> getLaunchSiteId() async {
    if (!Platform.isAndroid) return null;
    try {
      return await _channel.invokeMethod('getLaunchSiteId');
    } on PlatformException {
      return null;
    }
  }

  /// Get the set of siteIds that currently have a pinned home shortcut.
  static Future<Set<String>> getPinnedSiteIds() async {
    if (!Platform.isAndroid) return const <String>{};
    try {
      final result = await _channel.invokeMethod('getPinnedSiteIds');
      if (result is List) {
        return result.whereType<String>().toSet();
      }
      return const <String>{};
    } on PlatformException {
      return const <String>{};
    }
  }
}
