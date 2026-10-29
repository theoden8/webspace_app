import 'dart:async';
import 'package:webspace/settings/site_ids.dart';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/startup_controller.dart' show Launched, Reached, SitesOnPage;
import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/screens/home_shortcuts_settings.dart';
import 'package:webspace/services/icon_png_export.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/shortcut_service.dart';
import 'package:webspace/services/site_icon_store.dart';
import 'package:webspace/services/startup_restore_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/settings/shortcut_id.dart';
import 'package:webspace/web_view_model.dart';

/// A shortcut tapped after its site is gone, with no site on its domain
/// (HS-011).
enum MissingShortcutChoice { reroute, create }

/// What becomes of the pinned tiles of a deleted site (HS-013).
enum ShortcutFate { keep, reassign, disable }

/// A shortcut tap: what it resolved to, and on Android the tile tapped, so a
/// choice the user makes about it rewrites that tile (HS-017).
typedef _Tap = ({LaunchResolution<WebViewModel> resolution, ShortcutId? tile});

/// The questions the shortcut flows put to the user.
abstract interface class ShortcutPrompts {
  /// HS-011: open [siteName] for a shortcut whose own site is gone.
  Future<bool> confirmOpen(String siteName);

  /// HS-011 step 3: reroute or create for a gone site with no domain match.
  Future<MissingShortcutChoice?> missingSite(String url);

  /// HS-013: the launcher tiles of a site just deleted.
  Future<ShortcutFate?> deletedSiteTiles();

  /// A site to point a shortcut at, as its siteId.
  Future<SiteId?> pickSite(List<WebViewModel> candidates);

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

  /// A shortcut tap is an app entry point: the site it opens comes up with
  /// nothing over the page, neither a pushed route nor a revealed tab strip.
  void resetForEntry();

  Future<void> activate(WebViewModel site);
  void enterFullscreen();

  /// Sends the always-open-home siblings of [launched] home (HS-007,
  /// TAB-014).
  Future<void> resetHomeOnLaunch(WebViewModel launched);

  /// Adds [model] and puts it on screen.
  Future<void> registerSite(WebViewModel model);
}

/// Home shortcuts (HS-*): pinning, launches, and what a tile keeps pointing
/// at once its site is gone.
class ShortcutController implements HomeShortcutsHost {
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

  /// Each enabled pinned Android tile and the site its launch intent names
  /// (HS-017), as the launcher last reported them.
  Map<ShortcutId, SiteId> _pinned = const {};

  /// HS-004: whether this device can add a home shortcut. Probed once so the
  /// menu renders synchronously.
  bool _canAddShortcuts = false;

  /// HS-011 (Android): a pinned tile's intent names only a siteId, which is
  /// opaque once its site is deleted, so `siteId -> url` is kept for the
  /// sites tiles name, pruned to the pinned/current set, to drive the domain
  /// fallback.
  Map<SiteId, String> _urlLedger = {};

  /// HS-011 (iOS): iOS cannot enumerate home-screen tiles, so a bounded list
  /// of deleted `{siteId, label, url}` is synced to the App Group:
  /// `entities(for:)` resolves a deleted-site Shortcut from live ∪ tombstones
  /// while the picker stays live-only (HS-009).
  List<ShortcutTombstone> _tombstones = [];

  /// A confirmed rebind (stale siteId -> live siteId), so later taps of the
  /// same shortcut resolve silently. Machine state, not a user setting:
  /// excluded from backups. Written on iOS, where a Shortcuts tile cannot be
  /// rewritten; an Android tile is rewritten instead (HS-017), so Android
  /// only still reads the entries an earlier version wrote.
  Map<SiteId, SiteId> _remap = {};

  /// What each pinned Android tile was last given (HS-016). Held in memory
  /// only, so a launch's first sync rewrites every tile once, which also
  /// brings a tile pinned by an earlier version up to date.
  Map<ShortcutId, TileFace> _tileFaces = const {};
  StreamSubscription<String?>? _siteIconChanges;
  final _homeShortcuts = ValueNotifier<List<HomeShortcut>>(const []);

  /// A cold-launch tap that needs a prompt, parked until the first frame:
  /// there is no UI mid-restore.
  _Tap? _parked;

  /// The restore's proof, kept for the refresh the settings list asks for.
  Reached<SitesOnPage>? _sitesOnPage;
  final _promptGuard = ReentryGuard();

  /// A pinned tile takes its site's page icon once the webview reports one.
  void start() {
    if (!hostIsAndroid) return;
    _siteIconChanges =
        SiteIconStore.instance.changes.listen((_) => _syncTiles());
  }

  void dispose() {
    unawaited(_siteIconChanges?.cancel());
    _homeShortcuts.dispose();
  }

  void load(SharedPreferences prefs) {
    _remap = {
      for (final MapEntry(:key, :value)
          in _decodeStringMap(prefs.getString(_kRemapKey)).entries)
        if ((SiteId.parse(key), SiteId.parse(value))
            case (final tile?, final site?))
          tile: site,
    };
    _urlLedger = {
      for (final MapEntry(:key, :value)
          in _decodeStringMap(prefs.getString(_kUrlLedgerKey)).entries)
        ?SiteId.parse(key): value,
    };
    _tombstones = _decodeTombstones(prefs.getString(_kTombstonesKey));
  }

  Future<void> probeSupport() async {
    final supported = await ShortcutService.canAddShortcuts();
    if (!_host.mounted || supported == _canAddShortcuts) return;
    _canAddShortcuts = supported;
    _host.rebuild();
  }

  /// HS-004 / HS-005: whether the menu offers a shortcut for [model]: never
  /// where the device cannot add one, on Android not while a pinned tile opens
  /// the site, on iOS 16+ / macOS 13+ always (no API reports a pin).
  bool offersShortcutFor(WebViewModel model) {
    // ARCH-006: an OS-level shortcut would name an archived site.
    if (model.isArchiveTier || !_canAddShortcuts) return false;
    if (!hostIsAndroid) return true;
    return ShortcutPinState.tilesReaching(
      siteId: model.siteId,
      pinned: _pinned,
      rememberedRemap: _remap,
      models: _sites.models,
    ).isEmpty;
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
        proxy: model.outboundProxy,
      );
      if (!_host.mounted) return;
      final pinned = await ShortcutService.pinShortcut(
        siteId: model.siteId,
        label: model.name,
        shortcutId: ShortcutId.mint(),
        iconBytes: iconBytes,
      );
      // HS-011: so a later delete+recreate can route by domain.
      await _recordLedger(model.siteId, url: model.initUrl);
      switch (pinned) {
        case PinShortcutResult.requested:
          break;
        case PinShortcutResult.failed:
          _host.toast((loc) => loc.homeShortcutPinFailed(model.name));
      }
      return;
    }
    if (!(hostIsIOS || hostIsMacOS) || !_canAddShortcuts) return;
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
  Future<void> refreshPinned({required Reached<SitesOnPage> after}) async {
    final tiles = await ShortcutService.getPinnedShortcuts();
    if (!_host.mounted) return;
    await _reconcileLedger(tiles.values.toSet());
    if (!_host.mounted) return;
    if (mapEquals(tiles, _pinned)) return;
    _pinned = tiles;
    _host.rebuild();
    _syncTiles();
    _publishHomeShortcuts();
  }

  /// Drops remembered state naming sites that no longer exist: a remap whose
  /// target is gone would never resolve (a fresh tap re-prompts), and a
  /// tombstone whose site is live again (only a backup can do that).
  Future<void> pruneAgainst(
    Set<SiteId> liveSiteIds, {
    required Reached<SitesOnPage> after,
  }) async {
    _sitesOnPage = after;
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
      await prefs.setString(_kTombstonesKey, _encodeTombstones(_tombstones));
    }
  }

  /// A cold launch: the site to activate for a shortcut that resolves to
  /// one, with the Always open Home resets done (HS-006, HS-007), or null.
  /// A launch that needs a prompt is parked for [promptParkedAfterFrame].
  Future<WebViewModel?> resolveColdLaunch({
    required Reached<SitesOnPage> after,
  }) async {
    final tap = await _resolveLaunch(warm: false);
    final resolution = tap.resolution;
    if (resolution is! LaunchOpenSite<WebViewModel>) {
      if (resolution is! LaunchNone<WebViewModel>) _parked = tap;
      return null;
    }
    final site = resolution.site;
    _host.kioskLocked = site.kioskMode;
    await _host.resetHomeOnLaunch(site);
    if (!_host.mounted) return null;
    return site;
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
  Future<void> handleWarmLaunch({required Reached<Launched> after}) async {
    final tap = await _resolveLaunch(warm: true);
    if (!_host.mounted) return;
    if (tap.resolution case LaunchOpenSite(:final site)) {
      await _open(site);
    } else if (tap.resolution is! LaunchNone) {
      await _applyInteractive(tap);
    }
  }

  Future<_Tap> _resolveLaunch({required bool warm}) async {
    const none = (resolution: LaunchNone<WebViewModel>(), tile: null);
    final launch = await ShortcutService.getLaunch();
    if (launch == null) return none;
    if (warm) {
      if (!_host.mounted) return none;
      _host.resetForEntry();
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
    return (
      resolution: StartupRestoreEngine.resolveLaunch(
        shortcutSiteId: launch.siteId,
        shortcutUrl: url,
        models: _sites.models,
        rememberedRemap: _remap,
      ),
      tile: launch.shortcutId,
    );
  }

  String? _tombstoneUrlFor(SiteId siteId) {
    for (final t in _tombstones) {
      if (t.siteId == siteId) return t.url;
    }
    return null;
  }

  /// Warm-tap switch to a resolved site: siblings home (HS-007), switch if
  /// not already on screen, persist. The site's own page is kept: a warm tap
  /// preserves the live session (HS-006).
  Future<void> _open(WebViewModel site) async {
    if (!_sites.models.contains(site)) return;
    // KIOSK-001: a kiosk site locks the shell; any other clears the lock.
    _host.kioskLocked = site.kioskMode;
    await _host.resetHomeOnLaunch(site);
    if (!_host.mounted) return;
    if (site != _sites.shown) {
      await _host.activate(site);
      if (!_host.mounted) return;
    }
    // FS-008, after the activation exited full screen for a non-full-screen
    // target, so there is no else.
    if (_host.kioskLocked ||
        StartupRestoreEngine.shouldEnterFullscreen(
          viaShortcut: true,
          fullscreenOnShortcut: AppPref.fullscreenOnShortcut.value,
          perSiteFullscreenMode: site.fullscreenMode,
        )) {
      _host.enterFullscreen();
    }
    _host.rebuild();
    await _host.commitSites(const SitesEdited());
  }

  /// HS-011: the prompts for a shortcut whose siteId no longer maps to a
  /// site. Every choice is kept, so the next tap is direct.
  Future<void> _applyInteractive(_Tap tap) async {
    final tile = tap.tile;
    await _promptGuard.run(() async {
      switch (tap.resolution) {
        case LaunchConfirmExisting(:final site, :final shortcutSiteId):
          if (!_sites.models.contains(site)) return;
          if (!await _prompts.confirmOpen(site.getDisplayName()) ||
              !_host.mounted) {
            return;
          }
          await _rebind(shortcutSiteId, tile: tile, to: site.siteId);
          await _open(site);
        case LaunchOfferCreate(:final url, :final shortcutSiteId):
          final choice = await _prompts.missingSite(url);
          if (choice == null || !_host.mounted) return;
          switch (choice) {
            case MissingShortcutChoice.reroute:
              await _reroute(shortcutSiteId, tile: tile);
            case MissingShortcutChoice.create:
              final model =
                  WebViewModel(initUrl: url, stateSetterF: _host.rebuild);
              final title = await getPageTitle(url, proxy: model.outboundProxy);
              if (!_host.mounted) return;
              if (title != null && title.isNotEmpty) {
                model.name = title;
                model.pageTitle = title;
              }
              await _host.registerSite(model);
              if (!_host.mounted) return;
              await _rebind(shortcutSiteId, tile: tile, to: model.siteId);
          }
        case LaunchOfferReroute(:final shortcutSiteId):
          // A handle resolved to a placeholder: site removed, no url known.
          await _reroute(shortcutSiteId, tile: tile);
        case LaunchNone() || LaunchOpenSite():
          return;
      }
    });
  }

  Future<void> _reroute(SiteId shortcutSiteId,
      {required ShortcutId? tile}) async {
    final targetSiteId = await _pickSite();
    if (targetSiteId == null || !_host.mounted) return;
    await _rebind(shortcutSiteId, tile: tile, to: targetSiteId);
    if (_sites.byId(targetSiteId) case final site?) await _open(site);
  }

  /// Keeps the user's answer for a tapped shortcut: an Android tile is
  /// rewritten to open [to] (HS-017); a Shortcuts tile, which the app cannot
  /// rewrite, gets a remembered remap from the site it names.
  Future<void> _rebind(SiteId shortcutSiteId,
      {required ShortcutId? tile, required SiteId to}) async {
    if (hostIsAndroid && tile != null) {
      _pointTile(tile, to: to);
      return;
    }
    await _rememberRemap(shortcutSiteId, resolvedSiteId: to);
  }

  Future<SiteId?> _pickSite({SiteId? except}) async {
    final candidates = [
      for (final m in _sites.models)
        if (!m.isArchiveTier && m.siteId != except) m,
    ];
    if (candidates.isEmpty || !_host.mounted) return null;
    return _prompts.pickSite(candidates);
  }

  /// HS-013: the launcher tiles that open [model], read fresh from the
  /// launcher before the delete. Android only; elsewhere no tile can be
  /// enumerated.
  Future<Set<ShortcutId>> tilesReaching(WebViewModel model) async {
    if (!hostIsAndroid) return const {};
    final pinnedNow = await ShortcutService.getPinnedShortcuts();
    final tiles = ShortcutPinState.tilesReaching(
      siteId: model.siteId,
      pinned: pinnedNow,
      rememberedRemap: _remap,
      models: _sites.models,
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
      {required Set<ShortcutId> tiles}) async {
    if (tiles.isNotEmpty && _host.mounted) await _decideTileFate(tiles);
    if ((hostIsIOS || hostIsMacOS) && !deleted.isArchiveTier) {
      await _recordTombstone(deleted.siteId,
          label: deleted.name, url: deleted.initUrl);
    }
  }

  /// Keep the tiles (a tap re-routes), point them at another site, or
  /// disable them; Android cannot remove a tile for the user.
  Future<void> _decideTileFate(Set<ShortcutId> tileIds) async {
    final choice = await _prompts.deletedSiteTiles();
    if (!_host.mounted) return;
    switch (choice) {
      case null || ShortcutFate.keep:
        return;
      case ShortcutFate.disable:
        await _disableTiles(tileIds);
      case ShortcutFate.reassign:
        final targetSiteId = await _pickSite();
        if (targetSiteId == null || !_host.mounted) return;
        for (final tile in tileIds) {
          _pointTile(tile, to: targetSiteId);
        }
    }
  }

  /// Greys [tileIds] out, and forgets what only they kept: the rebind and
  /// the url of a gone site no remaining tile names.
  Future<void> _disableTiles(Set<ShortcutId> tileIds) async {
    for (final tile in tileIds) {
      await ShortcutService.disableShortcut(tile);
    }
    if (!_host.mounted) return;
    _pinned = {..._pinned}..removeWhere((tile, _) => tileIds.contains(tile));
    final stillNamed = _pinned.values.toSet();
    final remapBefore = _remap.length;
    _remap.removeWhere((named, _) => !stillNamed.contains(named));
    if (_remap.length != remapBefore) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_kRemapKey, jsonEncode(_remap));
    }
    await _reconcileLedger(stillNamed);
    if (!_host.mounted) return;
    _host.rebuild();
    _publishHomeShortcuts();
  }

  /// HS-017: [tile] opens [to] from now on, and takes its name and icon
  /// (HS-016) through the next tile sync, which this runs.
  void _pointTile(ShortcutId tile, {required SiteId to}) {
    _pinned = {..._pinned, tile: to};
    final url = _sites.models
        .where((m) => m.siteId == to)
        .map((m) => m.initUrl)
        .firstOrNull;
    if (url != null) unawaited(_recordLedger(to, url: url));
    _host.rebuild();
    _syncTiles();
    _publishHomeShortcuts();
  }

  @override
  ValueListenable<List<HomeShortcut>> get homeShortcuts => _homeShortcuts;

  @override
  Future<void> refreshHomeShortcuts() async {
    _publishHomeShortcuts();
    // The settings list opens only once the sites are on the page.
    if (_sitesOnPage case final onPage?) await refreshPinned(after: onPage);
  }

  @override
  Future<void> reassignHomeShortcut(ShortcutId id) async {
    final opens = ShortcutPinState.sitesOpened(
      pinned: _pinned,
      rememberedRemap: _remap,
      models: _sites.models,
    )[id];
    final targetSiteId = await _pickSite(except: opens?.siteId);
    if (targetSiteId == null || !_host.mounted) return;
    _pointTile(id, to: targetSiteId);
    final target = _sites.models.where((m) => m.siteId == targetSiteId);
    if (target.isEmpty) return;
    _host.toast((loc) => loc.homeShortcutNowOpens(target.first.name));
  }

  @override
  Future<void> disableHomeShortcut(ShortcutId id) => _disableTiles({id});

  /// The list App Settings shows: tiles that open a site, by name, then the
  /// ones whose site is gone.
  void _publishHomeShortcuts() {
    if (!hostIsAndroid) return;
    final opened = ShortcutPinState.sitesOpened(
      pinned: _pinned,
      rememberedRemap: _remap,
      models: _sites.models,
    );
    _homeShortcuts.value = [
      for (final MapEntry(key: id, value: site) in opened.entries)
        (id: id, opens: site, url: _urlLedger[_pinned[id]]),
    ]..sort((a, b) => switch ((a.opens, b.opens)) {
          (final x?, final y?) =>
            x.getDisplayName().compareTo(y.getDisplayName()),
          (null, null) => 0,
          (null, _) => 1,
          (_, null) => -1,
        });
  }

  /// The shortcuts follow the site list. HS-007: the iOS App Intents picker
  /// takes renames, additions and deletions, with tombstones resolving a
  /// deleted site's tile (HS-011). HS-016: a pinned Android tile takes the
  /// name and icon of the site it opens.
  void syncSites() {
    if (hostIsAndroid) {
      _syncTiles();
      _publishHomeShortcuts();
      return;
    }
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
        ShortcutSite(siteId: t.siteId, label: t.label, url: t.url),
    ];
    unawaited(ShortcutService.syncSites(sites, tombstones: tombstones));
  }

  /// The tile writes stay in call order: nothing between the plan and its
  /// turn in `ShortcutService.updateTiles` awaits.
  void _syncTiles() {
    if (!hostIsAndroid || !_host.mounted) return;
    final sitesOfTiles = ShortcutPinState.sitesOfTiles(
      pinned: _pinned,
      rememberedRemap: _remap,
      models: _sites.models,
    );
    final plan = ShortcutPinState.staleTiles(
      want: {
        for (final MapEntry(key: tile, value: site) in sitesOfTiles.entries)
          tile: (
            site: site.siteId,
            label: site.name,
            icon: knownSiteIcon(site.initUrl, customIcon: site.customIconPng),
          ),
      },
      shown: _tileFaces,
    );
    if (plan.updates.isEmpty) return;
    unawaited(ShortcutService.updateTiles(plan.updates).then((written) {
      if (written) _tileFaces = plan.shown;
    }));
  }

  Future<void> _rememberRemap(
    SiteId shortcutSiteId, {
    required SiteId resolvedSiteId,
  }) async {
    if (_remap[shortcutSiteId] == resolvedSiteId) return;
    _remap[shortcutSiteId] = resolvedSiteId;
    // The rebound tile now opens another site, so it takes that one's face.
    _syncTiles();
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRemapKey, jsonEncode(_remap));
  }

  Future<void> _recordTombstone(SiteId siteId,
      {required String label, required String url}) async {
    _tombstones = ShortcutTombstones.add(
      tombstones: _tombstones,
      entry: (siteId: siteId, label: label, url: url),
    );
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kTombstonesKey, _encodeTombstones(_tombstones));
    syncSites();
  }

  Future<void> _recordLedger(SiteId siteId, {required String url}) async {
    if (url.isEmpty || _urlLedger[siteId] == url) return;
    _urlLedger[siteId] = url;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kUrlLedgerKey, jsonEncode(_urlLedger));
  }

  /// HS-011: urls for the sites pinned tiles name while they exist;
  /// unreachable entries go.
  Future<void> _reconcileLedger(Set<SiteId> pinnedSiteIds) async {
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

  static List<ShortcutTombstone> _decodeTombstones(String? raw) {
    if (raw == null) return [];
    final decoded = _tryJson(raw);
    if (decoded is! List) return [];
    return [
      for (final e in decoded)
        if (e is Map)
          if (SiteId.parse(e['siteId']) case final siteId?)
            (
              siteId: siteId,
              label: e['label']?.toString() ?? '',
              url: e['url']?.toString() ?? '',
            ),
    ];
  }

  static String _encodeTombstones(List<ShortcutTombstone> tombstones) =>
      jsonEncode([
        for (final t in tombstones)
          {'siteId': t.siteId, 'label': t.label, 'url': t.url},
      ]);

  static Object? _tryJson(String raw) {
    try {
      return jsonDecode(raw);
    } on FormatException {
      return null;
    }
  }
}
