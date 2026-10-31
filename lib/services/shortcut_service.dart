import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/settings/site_ids.dart';
import 'dart:typed_data';
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter/services.dart';
import 'package:webspace/services/launcher_tile_engine.dart';
import 'package:webspace/services/startup_restore_engine.dart'
    show TileUpdate;
import 'package:webspace/utils/concurrency.dart';

/// One site as it crosses the platform-channel boundary into the iOS App
/// Intents picker (HS-007). `iconUrl` is reserved for future favicon syncing
/// and is currently unused on the Swift side. `url` lets the iOS `SiteEntity`
/// carry the site address so an orphaned Shortcut (a tile bound to a deleted
/// site, resolved via the tombstone list) can route by domain (HS-011).
class ShortcutSite {
  final SiteId siteId;
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

/// What a tapped home shortcut hands back: the `siteId` it opens, plus on
/// iOS the site's `url` carried through the App Group (`OpenSiteIntent`
/// writes it) and on Android the tile's own [shortcutId] (HS-017). Android
/// carries no url; the caller supplies it from the url ledger instead.
class ShortcutLaunch {
  final SiteId siteId;
  final String? url;
  final ShortcutId? shortcutId;

  const ShortcutLaunch({required this.siteId, this.url, this.shortcutId});
}

enum PinShortcutResult {
  /// The system pin dialog opened (Android), or Shortcuts.app did (iOS/macOS).
  requested,

  failed;

  static PinShortcutResult fromChannel(Object? raw) =>
      raw == true ? requested : failed;
}

class ShortcutService {
  static const _channel = MethodChannel('org.codeberg.theoden8.webspace/shortcuts');

  /// Tile writes reach the launcher in call order: building a tile awaits,
  /// and a later write whose tiles build sooner must not land first.
  static final SerialQueue _tileWrites = SerialQueue('shortcutTileWrites');

  /// Request a pinned home screen shortcut for a site.
  ///
  /// Android: hands a tile with its own fresh [shortcutId] (HS-017) to
  /// `ShortcutManagerCompat.requestPinShortcut`. iOS 16+: opens the
  /// Shortcuts app — the caller is responsible for showing the
  /// instructional dialog (HS-008) before invoking. [PinShortcutResult.failed]
  /// on platforms without either path.
  ///
  /// [iconBytes] is the site's icon as a raster PNG (the caller rasterizes
  /// the favicon, including SVG, before invoking — Android's BitmapFactory
  /// can't decode SVG), sent as a tile of its own (HS-018). Without it the
  /// shortcut uses the WebSpace app icon.
  static Future<PinShortcutResult> pinShortcut({
    required SiteId siteId,
    required String label,
    ShortcutId? shortcutId,
    Uint8List? iconBytes,
  }) async {
    if (!hostIsAndroid && !hostIsIOS && !hostIsMacOS) {
      return PinShortcutResult.failed;
    }
    try {
      final result = await _channel.invokeMethod(
        'pinShortcut',
        await tileArguments(
          tile: shortcutId,
          site: siteId,
          label: label,
          siteIcon: iconBytes,
        ),
      );
      return PinShortcutResult.fromChannel(result);
    } on PlatformException {
      return PinShortcutResult.failed;
    } on MissingPluginException {
      return PinShortcutResult.failed;
    }
  }

  /// Drop any dynamic shortcut copy for a deleted site (Android only). The
  /// pinned launcher tile is deliberately left ENABLED: HS-011 routes a tap on
  /// an orphaned shortcut through the url ledger (open a domain match / offer
  /// to create), which only works if the launcher still launches the app.
  /// On iOS the App Intents site list is rebuilt from the user's actual sites
  /// by `syncSites`, so a deletion drops out of the picker implicitly.
  static Future<void> removeShortcut(SiteId siteId) async {
    if (!hostIsAndroid) return;
    try {
      await _channel.invokeMethod('removeShortcut', {'siteId': siteId});
    } on PlatformException {
      // Ignore — shortcut may not exist
    }
  }

  /// Get the launch target if the app was opened via a pinned shortcut
  /// (Android) or a Shortcuts.app `OpenSiteIntent` (iOS 16+). Drains the
  /// underlying pending state on read (consume-once), so callers polling on
  /// every resume don't re-navigate on a plain background/return.
  ///
  /// Android returns `{siteId, shortcutId}` (`url` null — the caller pairs it
  /// with the url ledger); iOS/macOS return `{siteId, url}`. A bare siteId
  /// string is still read, so the platforms share one call site.
  static Future<ShortcutLaunch?> getLaunch() async {
    if (!hostIsAndroid && !hostIsIOS && !hostIsMacOS) {
      return null;
    }
    try {
      final res = await _channel.invokeMethod('getLaunchSiteId');
      if (res is String) {
        return switch (SiteId.parse(res)) {
          final id? => ShortcutLaunch(siteId: id),
          null => null,
        };
      }
      if (res is Map) {
        if (SiteId.parse(res['siteId']) case final id?) {
          final url = res['url'];
          return ShortcutLaunch(
            siteId: id,
            url: url is String && url.isNotEmpty ? url : null,
            shortcutId: ShortcutId.parse(res['shortcutId']),
          );
        }
      }
      return null;
    } on PlatformException {
      return null;
    } on MissingPluginException {
      // No shortcuts channel on this build (e.g. macOS integration-test
      // host where the plugin isn't registered) means no pending launch.
      return null;
    }
  }

  /// The enabled pinned home shortcuts, each with the site its launch intent
  /// names (HS-017). A disabled tile is left out: it opens nothing.
  /// Android-only — iOS has no public API to enumerate home-screen tiles, so
  /// this is always empty there.
  static Future<Map<ShortcutId, SiteId>> getPinnedShortcuts() async {
    if (!hostIsAndroid) return const {};
    try {
      final result = await _channel.invokeMethod('getPinnedShortcuts');
      if (result is! List) return const {};
      return {
        for (final tile in result)
          if (tile is Map)
            if ((ShortcutId.parse(tile['shortcutId']), SiteId.parse(tile['siteId']))
                case (final id?, final site?))
              id: site,
      };
    } on PlatformException {
      return const {};
    }
  }

  /// Rewrite pinned tiles (Android only): the site each opens (HS-017), its
  /// label, and its icon where one is given (HS-016). False when nothing was
  /// written: off Android, on a channel error, or when the launcher
  /// rate-limits the call, so the caller retries on its next sync.
  static Future<bool> updateTiles(List<TileUpdate> updates) async {
    if (!hostIsAndroid) return false;
    return _tileWrites.run(() async {
      try {
        final result = await _channel.invokeMethod('updateShortcuts', {
          'tiles': [
            for (final u in updates)
              await tileArguments(
                tile: u.tile,
                site: u.site,
                label: u.label,
                siteIcon: u.icon,
              ),
          ],
        });
        return result == true;
      } on PlatformException {
        return false;
      }
    });
  }

  /// What a tile crosses to native as: the id it is pinned under, the site
  /// it opens, its label, and [siteIcon] built into a tile with a background
  /// of its own (HS-018), built off the UI thread. A tile with no icon, or
  /// one that does not decode, sends none: an update keeps the tile's icon,
  /// a pin takes the app icon.
  @visibleForTesting
  static Future<Map<String, Object?>> tileArguments({
    required ShortcutId? tile,
    required SiteId site,
    required String label,
    required Uint8List? siteIcon,
  }) async =>
      {
        'shortcutId': tile,
        'siteId': site,
        'label': label,
        'iconBytes':
            siteIcon == null ? null : await compute(launcherTileIcon, siteIcon),
      };

  /// Disable a pinned shortcut (Android only). Android has no API to remove a
  /// pinned tile, so this greys it out and makes the launcher show "shortcut
  /// isn't available" on tap until the user drags it off the home screen.
  /// Only on the user's say-so (HS-013, HS-017): the default leaves a deleted
  /// site's tile tappable so it can re-route via the url ledger.
  static Future<void> disableShortcut(ShortcutId shortcutId) async {
    if (!hostIsAndroid) return;
    try {
      await _channel.invokeMethod('disableShortcut', {'shortcutId': shortcutId});
    } on PlatformException {
      // Ignore — shortcut may not exist.
    }
  }

  /// Push the user's current site list to the iOS App Intents picker (HS-007).
  /// Writes the live `sites` (shown in the Shortcuts.app picker) and the
  /// `tombstones` (recently-deleted sites — NOT shown in the picker, but kept
  /// resolvable so a Shortcut tile bound to a deleted site still launches and
  /// routes via HS-011) into the shared App Group UserDefaults. No-op on
  /// platforms without App Intents (everything but iOS/macOS).
  static Future<void> syncSites(
    List<ShortcutSite> sites, {
    List<ShortcutSite> tombstones = const [],
  }) async {
    if (!hostIsIOS && !hostIsMacOS) return;
    try {
      await _channel.invokeMethod('syncSites', {
        'sites': sites.map((s) => s.toMap()).toList(),
        'tombstones': tombstones.map((s) => s.toMap()).toList(),
      });
    } on PlatformException {
      // best-effort; the picker just shows stale data until next call.
    } on MissingPluginException {
      // Shortcuts channel absent on this build; nothing to sync.
    }
  }

  /// Whether this device can add a home shortcut at all (HS-004): on Android
  /// whether the default launcher takes pinned shortcuts (a TV launcher does
  /// not), on iOS 16+ / macOS 13+ whether App Intents are there. False on
  /// every other platform. Probed in main(), so the menu and App Settings
  /// read it synchronously, and where it is false nothing a shortcut decides
  /// is offered.
  static bool get offered => debugOfferedOverride ?? _offered;
  static bool _offered = false;

  /// Test and design gallery seam.
  static bool? debugOfferedOverride;

  static Future<void> probe() async {
    final method = hostIsAndroid
        ? 'canPinShortcuts'
        : hostIsIOS || hostIsMacOS
            ? 'isAppIntentsSupported'
            : null;
    if (method == null) return;
    try {
      _offered = await _channel.invokeMethod(method) == true;
    } on PlatformException {
      _offered = false;
    } on MissingPluginException {
      // macOS builds without the shortcuts channel handler (no App Intents
      // native side), and a background wake's engine, report no
      // implementation rather than a PlatformException.
      _offered = false;
    }
  }
}
