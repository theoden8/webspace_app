import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/icon_png_export.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';

/// A shortcut tapped after its site is gone, with no site on its domain
/// (HS-011).
enum MissingShortcutChoice { reroute, create }

/// What becomes of the pinned tiles of a deleted site (HS-013).
enum ShortcutFate { keep, reassign, disable }

/// The questions the shortcut flows put to the user.
abstract interface class ShortcutPrompts {
  /// HS-011: open [siteName] for a shortcut whose own site is gone.
  Future<bool> confirmOpen(String siteName);

  /// HS-011 step 3: reroute or create for a gone site with no domain match.
  Future<MissingShortcutChoice?> missingSite(String url);

  /// HS-013: the launcher tiles of a site just deleted.
  Future<ShortcutFate?> deletedSiteTiles();

  /// A site to point an orphaned shortcut at, as its siteId.
  Future<String?> pickSite(List<WebViewModel> candidates);

  /// HS-008 on iOS: how to add the site through Shortcuts.app.
  Future<void> explainIosShortcut(String siteName);

  /// HS-008 on macOS: whether to open Shortcuts.app for the site.
  Future<bool> confirmMacosShortcut(String siteName);
}

/// What the shortcut flows ask of the page.
abstract interface class ShortcutHost implements PageHost {
  /// KIOSK-001: a shortcut launch locks the shell to a kiosk site.
  set kioskLocked(bool locked);
  bool get kioskLocked;

  /// A shortcut tap is an app entry point: nothing pushed over the page may
  /// stay on top of the site it opens.
  void popToRoot();

  Future<void> activate(int index);
  void enterFullscreen();

  /// Sends the always-open-home siblings of [index] home (HS-007, TAB-014).
  Future<void> resetHomeOnLaunch(int index);

  /// Adds [model] and puts it on screen.
  Future<void> registerSite(WebViewModel model);
}

/// Home shortcuts (HS-*): pinning, launches, and what a tile keeps pointing
/// at once its site is gone.
class ShortcutController {
  ShortcutController(
    this._sites, {
    required ShortcutHost host,
    required ShortcutPrompts prompts,
  })  : _host = host,
        _prompts = prompts;

  final SiteRuntime _sites;
  final ShortcutHost _host;
  final ShortcutPrompts _prompts;

  static const _kUrlLedgerKey = 'shortcutUrlLedger';
  static const _kTombstonesKey = 'shortcutTombstones';
  static const _kRemapKey = 'shortcutSiteRemap';

  /// Sites that already have a pinned shortcut, so the menu item hides for
  /// them (HS-005).
  Set<String> _pinnedSiteIds = const <String>{};

  /// HS-006/007: iOS 16+ / macOS 13+ expose shortcuts via App Intents.
  /// Probed once so the menu renders synchronously.
  bool _appIntentsSupported = false;

  /// HS-011 (Android): a pinned shortcut's intent carries only the random
  /// siteId, which is opaque once its site is deleted, so `siteId -> url` is
  /// kept for pinned sites, pruned to the pinned/current set, to drive the
  /// domain fallback.
  Map<String, String> _urlLedger = {};

  /// HS-011 (iOS): iOS cannot enumerate home-screen tiles, so a bounded list
  /// of deleted `{siteId, label, url}` is synced to the App Group:
  /// `entities(for:)` resolves a deleted-site Shortcut from live ∪ tombstones
  /// while the picker stays live-only (HS-009).
  List<Map<String, String>> _tombstones = [];

  /// A confirmed rebind (stale siteId -> live siteId), so later taps of the
  /// same shortcut resolve silently. Machine state, not a user setting:
  /// excluded from backups.
  Map<String, String> _remap = {};

  /// A cold-launch resolution that needs a prompt, parked until the first
  /// frame: there is no UI mid-restore.
  LaunchResolution? _parked;
  final _promptGuard = ReentryGuard();

  void load(SharedPreferences prefs) {
    _remap = _decodeStringMap(prefs.getString(_kRemapKey));
    _urlLedger = _decodeStringMap(prefs.getString(_kUrlLedgerKey));
    _tombstones = _decodeTombstones(prefs.getString(_kTombstonesKey));
  }

  Future<void> probeAppIntents() async {
    final supported = await ShortcutService.isAppIntentsSupported();
    if (!_host.mounted || supported == _appIntentsSupported) return;
    _appIntentsSupported = supported;
    _host.rebuild();
  }

  /// HS-004 / HS-005: whether the menu offers a shortcut for [model]. Android
  /// hides it once the site has one; iOS 16+ / macOS 13+ always offer it (no
  /// API reports a pin); elsewhere there is no shortcut.
  bool offersShortcutFor(WebViewModel model) {
    // ARCH-006: an OS-level shortcut would name an archived site.
    if (model.isArchiveTier) return false;
    if (hostIsAndroid) {
      // A site an orphaned tile was rebound to is reachable by that tile.
      final effective = ShortcutPinState.effectivePinnedSiteIds(
        pinnedSiteIds: _pinnedSiteIds,
        rememberedRemap: _remap,
      );
      return !effective.contains(model.siteId);
    }
    if (hostIsIOS || hostIsMacOS) return _appIntentsSupported;
    return false;
  }

  /// The "Home Shortcut" menu item. Android pins directly; iOS and macOS go
  /// through Shortcuts.app (HS-008).
  Future<void> addToHome(WebViewModel model) async {
    if (hostIsAndroid) {
      // Rasterised here (HS-003): Android's BitmapFactory cannot decode SVG,
      // so an SVG favicon would fall back to the app icon. The page-chosen URL
      // is never handed to native for a direct retry (LEAK-003). A user-chosen
      // icon is already a normalised PNG and wins.
      final iconBytes = await displayedSiteIconAsPng(
        model.initUrl,
        customIcon: model.customIconPng,
        resolvedIconUrl: FaviconUrlCache.get(model.initUrl),
        proxy: model.outboundProxySettings,
      );
      if (!_host.mounted) return;
      final pinned = await ShortcutService.pinShortcut(
        siteId: model.siteId,
        label: model.name,
        iconBytes: iconBytes,
      );
      // HS-011: so a later delete+recreate can route by domain.
      await _recordLedger(model.siteId, url: model.initUrl);
      switch (pinned) {
        case PinShortcutResult.requested:
          break;
        case PinShortcutResult.alreadyPinned:
          // No pin dialog backgrounds the app, so no resume refreshes the set.
          await refreshPinned();
          _host.toast((loc) => loc.homeShortcutReenabled(model.name));
        case PinShortcutResult.failed:
          _host.toast((loc) => loc.homeShortcutPinFailed(model.name));
      }
      return;
    }
    if (!(hostIsIOS || hostIsMacOS) || !_appIntentsSupported) return;
    if (hostIsIOS) {
      await _prompts.explainIosShortcut(model.name);
      return;
    }
    if (await _prompts.confirmMacosShortcut(model.name)) {
      await ShortcutService.pinShortcut(siteId: model.siteId, label: model.name);
    }
  }

  /// Re-reads the launcher's pinned set; on every resume, since a pin dialog
  /// or a removal from the launcher happens outside the app.
  Future<void> refreshPinned() async {
    final ids = await ShortcutService.getPinnedSiteIds();
    if (!_host.mounted) return;
    await _reconcileLedger(ids);
    if (!_host.mounted) return;
    if (setEquals(ids, _pinnedSiteIds)) return;
    _pinnedSiteIds = ids;
    _host.rebuild();
  }

  /// Drops remembered state naming sites that no longer exist: a remap whose
  /// target is gone would never resolve (a fresh tap re-prompts), and a
  /// tombstone whose site is live again (only a backup can do that).
  Future<void> pruneAgainst(Set<String> liveSiteIds) async {
    final prefs = await SharedPreferences.getInstance();
    final remapBefore = _remap.length;
    _remap.removeWhere((_, resolved) => !liveSiteIds.contains(resolved));
    if (_remap.length != remapBefore) {
      await prefs.setString(_kRemapKey, jsonEncode(_remap));
    }
    final tombstonesBefore = _tombstones.length;
    _tombstones =
        ShortcutTombstones.pruneLive(_tombstones, liveSiteIds: liveSiteIds);
    if (_tombstones.length != tombstonesBefore) {
      await prefs.setString(_kTombstonesKey, jsonEncode(_tombstones));
    }
  }

  /// A cold launch: the index to activate for a shortcut that resolves to a
  /// site, with the Always open Home resets done (HS-006, HS-007), or null.
  /// A launch that needs a prompt is parked for [promptParkedAfterFrame].
  Future<int?> resolveColdLaunch() async {
    final resolution = await _resolveLaunch(warm: false);
    if (resolution is! LaunchOpenSite) {
      if (resolution is! LaunchNone) _parked = resolution;
      return null;
    }
    final index = resolution.index;
    _host.kioskLocked = _sites.models[index].kioskMode;
    await _host.resetHomeOnLaunch(index);
    if (!_host.mounted) return null;
    return index;
  }

  void promptParkedAfterFrame() {
    if (_parked == null) return;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      final parked = _parked;
      _parked = null;
      if (parked == null || !_host.mounted) return;
      unawaited(_applyInteractive(parked));
    });
  }

  /// A shortcut tapped while the app runs.
  Future<void> handleWarmLaunch() async {
    final resolution = await _resolveLaunch(warm: true);
    if (!_host.mounted) return;
    if (resolution is LaunchOpenSite) {
      await _openIndex(resolution.index);
    } else if (resolution is! LaunchNone) {
      await _applyInteractive(resolution);
    }
  }

  Future<LaunchResolution> _resolveLaunch({required bool warm}) async {
    final launch = await ShortcutService.getLaunch();
    if (launch == null) return const LaunchNone();
    if (warm) {
      if (!_host.mounted) return const LaunchNone();
      _host.popToRoot();
    }
    // iOS carries the url in the launch payload; Android pairs the id with
    // its url ledger; the iOS tombstone is the last resort for a stale cached
    // entity without one.
    final url = launch.url ??
        _urlLedger[launch.siteId] ??
        _tombstoneUrlFor(launch.siteId);
    LogTag.shortcut.debug(
        '${warm ? 'warm' : 'cold'} launch siteId=${launch.siteId} payloadUrl=${launch.url} '
        'resolvedUrl=$url', sensitive: true);
    return StartupRestoreEngine.resolveLaunch(
      shortcutSiteId: launch.siteId,
      shortcutUrl: url,
      models: _sites.models,
      rememberedRemap: _remap,
    );
  }

  String? _tombstoneUrlFor(String siteId) {
    for (final t in _tombstones) {
      if (t['siteId'] == siteId) return t['url'];
    }
    return null;
  }

  /// Warm-tap switch to a resolved site: siblings home (HS-007), switch if
  /// not already on screen, persist. The site's own page is kept: a warm tap
  /// preserves the live session (HS-006).
  Future<void> _openIndex(int index) async {
    if (index < 0 || index >= _sites.models.length) return;
    // KIOSK-001: a kiosk site locks the shell; any other clears the lock.
    _host.kioskLocked = _sites.models[index].kioskMode;
    await _host.resetHomeOnLaunch(index);
    if (!_host.mounted) return;
    if (index != _sites.current) {
      await _host.activate(index);
      if (!_host.mounted) return;
    }
    // FS-008, after the activation exited full screen for a non-full-screen
    // target, so there is no else.
    if (_host.kioskLocked ||
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: true,
          fullscreenOnShortcut: AppPref.fullscreenOnShortcut.value,
          perSiteFullscreenMode: _sites.models[index].fullscreenMode,
        )) {
      _host.enterFullscreen();
    }
    _host.rebuild();
    await _host.commitSites(const SitesEdited());
  }

  /// HS-011: the prompts for a shortcut whose siteId no longer maps to a
  /// site. Every choice is remembered as a remap so the next tap is direct.
  Future<void> _applyInteractive(LaunchResolution resolution) async {
    await _promptGuard.run(() async {
      switch (resolution) {
        case LaunchConfirmExisting(:final index, :final shortcutSiteId):
          if (index < 0 || index >= _sites.models.length) return;
          final model = _sites.models[index];
          if (!await _prompts.confirmOpen(model.getDisplayName()) ||
              !_host.mounted) {
            return;
          }
          await _rememberRemap(shortcutSiteId, resolvedSiteId: model.siteId);
          await _openIndex(index);
        case LaunchOfferCreate(:final url, :final shortcutSiteId):
          final choice = await _prompts.missingSite(url);
          if (choice == null || !_host.mounted) return;
          switch (choice) {
            case MissingShortcutChoice.reroute:
              await _reroute(shortcutSiteId);
            case MissingShortcutChoice.create:
              final model =
                  WebViewModel(initUrl: url, stateSetterF: _host.rebuild);
              final title = await getPageTitle(url);
              if (!_host.mounted) return;
              if (title != null && title.isNotEmpty) {
                model.name = title;
                model.pageTitle = title;
              }
              await _host.registerSite(model);
              if (!_host.mounted) return;
              await _rememberRemap(shortcutSiteId,
                  resolvedSiteId: model.siteId);
          }
        case LaunchOfferReroute(:final shortcutSiteId):
          // A handle resolved to a placeholder: site removed, no url known.
          await _reroute(shortcutSiteId);
        case LaunchNone() || LaunchOpenSite():
          return;
      }
    });
  }

  Future<void> _reroute(String shortcutSiteId) async {
    final targetSiteId = await _pickSite();
    if (targetSiteId == null || !_host.mounted) return;
    await _rememberRemap(shortcutSiteId, resolvedSiteId: targetSiteId);
    final i = _sites.models.indexWhere((m) => m.siteId == targetSiteId);
    if (i >= 0) await _openIndex(i);
  }

  Future<String?> _pickSite() async {
    final candidates = [
      for (final m in _sites.models)
        if (!m.isArchiveTier) m,
    ];
    if (candidates.isEmpty || !_host.mounted) return null;
    return _prompts.pickSite(candidates);
  }

  /// HS-013: the launcher tiles that reach [model], directly or through an
  /// HS-011 rebind, read fresh from the launcher before the delete. Android
  /// only; elsewhere no tile can be enumerated.
  Future<Set<String>> tilesReaching(WebViewModel model) async {
    if (!hostIsAndroid) return const {};
    final pinnedNow = await ShortcutService.getPinnedSiteIds();
    final tiles = ShortcutPinState.tilesReaching(
      siteId: model.siteId,
      pinnedSiteIds: pinnedNow,
      rememberedRemap: _remap,
    );
    LogTag.shortcut.debug(
        'delete siteId=${model.siteId} pinned=$pinnedNow reachingTiles=$tiles',
        sensitive: true);
    return tiles;
  }

  /// After [deleted] left the site list: ask what becomes of the [tiles]
  /// that reached it (HS-013), and on iOS/macOS tombstone it so a tile bound
  /// to it still routes by domain when tapped (HS-011/HS-014). Apple gives
  /// no way to tell whether a tile exists, so a prompt there would fire on
  /// every delete.
  Future<void> siteDeleted(WebViewModel deleted,
      {required Set<String> tiles}) async {
    if (tiles.isNotEmpty && _host.mounted) await _decideTileFate(tiles);
    if ((hostIsIOS || hostIsMacOS) && !deleted.isArchiveTier) {
      await _recordTombstone(deleted.siteId,
          label: deleted.name, url: deleted.initUrl);
    }
  }

  /// Keep the tiles (a tap re-routes), point them at another site, or
  /// disable them; Android cannot remove a tile for the user.
  Future<void> _decideTileFate(Set<String> tileIds) async {
    final choice = await _prompts.deletedSiteTiles();
    if (!_host.mounted) return;
    switch (choice) {
      case null || ShortcutFate.keep:
        return;
      case ShortcutFate.disable:
        for (final tile in tileIds) {
          await ShortcutService.disableShortcut(tile);
          _remap.remove(tile);
          _urlLedger.remove(tile);
        }
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString(_kRemapKey, jsonEncode(_remap));
        await prefs.setString(_kUrlLedgerKey, jsonEncode(_urlLedger));
        if (!_host.mounted) return;
        _pinnedSiteIds = {..._pinnedSiteIds}..removeAll(tileIds);
        _host.rebuild();
      case ShortcutFate.reassign:
        final targetSiteId = await _pickSite();
        if (targetSiteId == null || !_host.mounted) return;
        for (final tile in tileIds) {
          await _rememberRemap(tile, resolvedSiteId: targetSiteId);
        }
    }
  }

  /// HS-007: the iOS App Intents picker follows renames, additions and
  /// deletions, with tombstones resolving a deleted site's tile (HS-011).
  void syncSites() {
    if (!hostIsIOS && !hostIsMacOS) return;
    final sites = [
      for (final m in _sites.models)
        if (!m.isArchiveTier)
          ShortcutSite(
            siteId: m.siteId,
            label: m.name,
            url: m.initUrl,
            iconUrl: FaviconUrlCache.get(m.initUrl),
          ),
    ];
    final tombstones = [
      for (final t in _tombstones)
        ShortcutSite(
          siteId: t['siteId'] ?? '',
          label: t['label'] ?? '',
          url: t['url'],
        ),
    ];
    unawaited(ShortcutService.syncSites(sites, tombstones: tombstones));
  }

  Future<void> _rememberRemap(
    String shortcutSiteId, {
    required String resolvedSiteId,
  }) async {
    if (_remap[shortcutSiteId] == resolvedSiteId) return;
    _remap[shortcutSiteId] = resolvedSiteId;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemapKey, jsonEncode(_remap));
  }

  Future<void> _recordTombstone(String siteId,
      {required String label, required String url}) async {
    _tombstones = ShortcutTombstones.add(
      tombstones: _tombstones,
      entry: {'siteId': siteId, 'label': label, 'url': url},
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTombstonesKey, jsonEncode(_tombstones));
    syncSites();
  }

  Future<void> _recordLedger(String siteId, {required String url}) async {
    if (url.isEmpty || _urlLedger[siteId] == url) return;
    _urlLedger[siteId] = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrlLedgerKey, jsonEncode(_urlLedger));
  }

  /// HS-011: urls for pinned sites that still exist; unreachable entries go.
  Future<void> _reconcileLedger(Set<String> pinnedSiteIds) async {
    final next = ShortcutUrlLedger.reconcile(
      ledger: _urlLedger,
      currentSiteUrls: {
        for (final m in _sites.models)
          if (!m.isArchiveTier) m.siteId: m.initUrl,
      },
      pinnedSiteIds: pinnedSiteIds,
    );
    if (mapEquals(next, _urlLedger)) return;
    _urlLedger = next;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrlLedgerKey, jsonEncode(_urlLedger));
  }

  /// A corrupt entry reads as empty; the next update rewrites it.
  static Map<String, String> _decodeStringMap(String? raw) {
    if (raw == null) return {};
    final decoded = _tryJson(raw);
    if (decoded is! Map) return {};
    return {for (final e in decoded.entries) e.key.toString(): e.value.toString()};
  }

  static List<Map<String, String>> _decodeTombstones(String? raw) {
    if (raw == null) return [];
    final decoded = _tryJson(raw);
    if (decoded is! List) return [];
    return [
      for (final e in decoded)
        if (e is Map)
          {for (final kv in e.entries) kv.key.toString(): kv.value.toString()},
    ];
  }

  static Object? _tryJson(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}
