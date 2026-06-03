import 'dart:io';
import 'package:flutter/services.dart';

/// One site as it crosses the platform-channel boundary into the iOS App
/// Intents picker (HS-007). `iconUrl` is reserved for future favicon syncing
/// and is currently unused on the Swift side. `url` rides along so a launched
/// shortcut whose `siteId` no longer maps to a site can fall back to a
/// domain match (HS-011).
class ShortcutSite {
  final String siteId;
  final String label;
  final String? url;
  final String? iconUrl;

  const ShortcutSite({
    required this.siteId,
    required this.label,
    this.url,
    this.iconUrl,
  });

  Map<String, dynamic> toMap() => {
        'siteId': siteId,
        'label': label,
        if (url != null) 'url': url,
        if (iconUrl != null) 'iconUrl': iconUrl,
      };
}

/// What a tapped home shortcut hands back: the pinned `siteId` plus the site's
/// `url` (when the shortcut was created after HS-011). Older shortcuts predate
/// the `url` extra, so `url` is null for them and resolution degrades to
/// siteId-only matching.
class ShortcutLaunch {
  final String siteId;
  final String? url;

  const ShortcutLaunch({required this.siteId, this.url});
}

class ShortcutService {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  /// Request a pinned home screen shortcut for a site.
  ///
  /// Android: hands the request to `ShortcutManagerCompat.requestPinShortcut`
  /// and returns whether the system dialog opened. iOS 16+: opens the
  /// Shortcuts app — the caller is responsible for showing the
  /// instructional dialog (HS-008) before invoking. Returns false on
  /// platforms without either path.
  static Future<bool> pinShortcut({
    required String siteId,
    required String label,
    String? url,
    String? iconUrl,
  }) async {
    if (!Platform.isAndroid && !Platform.isIOS) return false;
    try {
      final result = await _channel.invokeMethod('pinShortcut', {
        'siteId': siteId,
        'label': label,
        'siteUrl': url,
        'iconUrl': iconUrl,
      });
      return result == true;
    } on PlatformException {
      return false;
    }
  }

  /// Remove a pinned shortcut when a site is deleted (Android only).
  /// On iOS the App Intents site list is rebuilt from the user's actual
  /// sites by `syncSites` so a deletion drops out implicitly.
  static Future<void> removeShortcut(String siteId) async {
    if (!Platform.isAndroid) return;
    try {
      await _channel.invokeMethod('removeShortcut', {'siteId': siteId});
    } on PlatformException {
      // Ignore — shortcut may not exist
    }
  }

  /// Get the launch target (siteId + url) if the app was opened via a pinned
  /// shortcut (Android) or a Shortcuts.app `OpenSiteIntent` (iOS 16+). Drains
  /// the underlying pending state on read (consume-once), so callers polling on
  /// every resume don't re-navigate on a plain background/return.
  ///
  /// The native side returns a `{siteId, url}` map for shortcuts pinned after
  /// HS-011; a bare string is tolerated for backward compatibility (url null).
  static Future<ShortcutLaunch?> getLaunch() async {
    if (!Platform.isAndroid && !Platform.isIOS) return null;
    try {
      final res = await _channel.invokeMethod('getLaunchSiteId');
      if (res is String) {
        return res.isEmpty ? null : ShortcutLaunch(siteId: res);
      }
      if (res is Map) {
        final id = res['siteId'];
        if (id is String && id.isNotEmpty) {
          final url = res['url'];
          return ShortcutLaunch(
            siteId: id,
            url: url is String && url.isNotEmpty ? url : null,
          );
        }
      }
      return null;
    } on PlatformException {
      return null;
    }
  }

  /// Get the set of siteIds that currently have a pinned home shortcut.
  /// Android-only — iOS has no public API to enumerate home-screen tiles, so
  /// this always returns an empty set on iOS.
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

  /// Push the user's current site list to the iOS App Intents picker
  /// (HS-007). Writes `[{id, name}]` into the shared App Group UserDefaults
  /// so `SiteEntityQuery` returns real sites. No-op on non-iOS platforms.
  static Future<void> syncSites(List<ShortcutSite> sites) async {
    if (!Platform.isIOS) return;
    try {
      await _channel.invokeMethod('syncSites', {
        'sites': sites.map((s) => s.toMap()).toList(),
      });
    } on PlatformException {
      // best-effort; the picker just shows stale data until next call.
    }
  }

  /// True iff the iOS App Intents-based path is available (iOS 16+). False
  /// on Android (Android uses its own pin path, not gated by this), on
  /// older iOS, and on every other platform.
  static Future<bool> isAppIntentsSupported() async {
    if (!Platform.isIOS) return false;
    try {
      final result = await _channel.invokeMethod('isAppIntentsSupported');
      return result == true;
    } on PlatformException {
      return false;
    }
  }
}
