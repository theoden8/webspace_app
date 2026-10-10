import 'dart:typed_data';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';
import 'package:webspace/services/cookie_manager.dart';

/// Why a passphrase is asked for; each reads differently.
enum PassphrasePurpose { moveSite, openArchive, restoreSections }

/// The questions the archive flows put to the user.
abstract interface class ArchivePrompts {
  Future<String?> passphrase(PassphrasePurpose purpose);

  /// No archive matched the passphrase given for [purpose]; whether to
  /// create one with it.
  Future<bool> createArchive(PassphrasePurpose purpose);

  /// Whether an export bundles the [count] open archives.
  Future<bool> includeOpenArchives(int count);
}

/// What the archive flows ask of the page.
abstract interface class ArchiveHost implements PageHost {
  /// The cookies [model]'s webview holds now, or its model's when it has
  /// none, so they ride along across the archive boundary.
  Future<List<Cookie>> captureCookies(WebViewModel model);
}

/// Which rows of the lists belong to one open archive, so a close removes
/// exactly those.
class _ArchiveSlice {
  _ArchiveSlice({
    required this.siteIds,
    required this.webspaceIds,
    required this.containerIds,
  });
  final Set<String> siteIds;
  final Set<String> webspaceIds;

  /// Opaque container ids of the archive's sites, deleted on close so no
  /// archive-tier container directory outlives it (ARCH-007).
  final Set<String> containerIds;
}

/// Passphrase-gated archives on the page (spec `archive`): opening one puts
/// its sites in the lists marked archive-tier, closing seals them back.
class ArchiveController {
  ArchiveController(
    this._sites, {
    required ArchiveHost host,
    required ArchivePrompts prompts,
    required this.containers,
    required this.cookieStore,
    required this.proxyPasswords,
    required this.navStates,
    required Archive archive,
  })  : _host = host,
        _prompts = prompts,
        _archive = archive;

  final SiteRuntime _sites;
  final ArchiveHost _host;
  final ArchivePrompts _prompts;
  final ContainerIsolationEngine containers;
  final CookieSecureStorage cookieStore;
  final ProxyPasswordSecureStorage proxyPasswords;
  final WebViewStateStorage navStates;

  /// Its slot pool initialises on first open or create, so a user who never
  /// touches the feature pays no secure-storage write at startup (ARCH-001).
  final Archive _archive;

  final Map<ArchiveHandle, _ArchiveSlice> _slices = {};

  bool get anyOpen => _slices.isNotEmpty;

  /// The open archive [m] belongs to, or null for an app-tier site.
  ArchiveHandle? archiveOf(WebViewModel m) => _slices.entries
      .where((e) => e.value.siteIds.contains(m.siteId))
      .firstOrNull
      ?.key;

  /// The handle for [passphrase] with its sites in the lists, or null when
  /// none matches. Done before returning: a caller writes into the handle
  /// and its slice right after.
  Future<ArchiveHandle?> open(String passphrase) async {
    final handle = await _archive.tryOpen(passphrase);
    if (handle == null) return null;
    if (_slices.containsKey(handle)) return handle;
    await _materialise(handle);
    return handle;
  }

  Future<ArchiveHandle> create(String passphrase) async {
    final handle = await _archive.create(passphrase);
    await _materialise(handle);
    return handle;
  }

  /// [handle]'s sites and named collections at the end of the lists, marked
  /// archive-tier so neither enters app-tier persistence (ARCH-001).
  Future<void> _materialise(ArchiveHandle handle) async {
    final sites = <WebViewModel>[];
    for (final siteJson in handle.state.sites) {
      final model = WebViewModel.fromJson(
        Map<String, dynamic>.from(siteJson),
        stateSetterF: _host.rebuild,
        isArchiveTier: true,
      );
      model.archiveContainerId =
          await _containerIdFor(handle.key, siteId: model.siteId);
      final cookieList = handle.state.cookies[model.siteId];
      if (cookieList != null && cookieList.isNotEmpty) {
        model.setPendingArchiveCookies([
          for (final c in cookieList)
            cookieFromJson(Map<String, dynamic>.from(c)),
        ]);
      }
      sites.add(model);
    }
    final webspaces = [
      for (final wsJson in handle.state.webspaces)
        Webspace.fromJson(Map<String, dynamic>.from(wsJson))
          ..isArchiveTier = true,
    ];
    _slices[handle] = _ArchiveSlice(
      siteIds: {for (final m in sites) m.siteId},
      webspaceIds: {for (final w in webspaces) w.id},
      containerIds: {for (final m in sites) m.archiveContainerId!},
    );
    await _host.commitSites(ArchiveOpened(
      sites: sites,
      webspaces: webspaces,
      appTierMembership: handle.state.appTierMembership,
    ));
  }

  /// ARCH-007: an HMAC of the archive key and the site id, shaped like an
  /// app-tier siteId (radix-36-dash-radix-36) so directory listings look
  /// uniform.
  static Future<String> _containerIdFor(
    Uint8List archiveKey, {
    required String siteId,
  }) async {
    final mac = await ArchiveCrypto.hmac(archiveKey, info: 'container:$siteId');
    final bd = ByteData.view(mac.buffer, mac.offsetInBytes);
    final v1 =
        (bd.getUint16(0) * 0x100000000) + bd.getUint32(2); // 48-bit group
    final v2 = bd.getUint32(6);
    return '${v1.toRadixString(36)}-${v2.toRadixString(36)}';
  }

  /// Seals [handle]: its sites, cookies and collections back into its state,
  /// saved; the key zeroed; its containers and every per-site trace outside
  /// the archive gone; its rows out of the lists. False when the sealed
  /// state does not fit its slot (ARCH-011): nothing changes and the
  /// archive stays open.
  Future<bool> close(ArchiveHandle handle) async {
    final slice = _slices[handle];
    if (slice == null) return true;
    final ownedSites = [
      for (final m in _sites.models)
        if (slice.siteIds.contains(m.siteId)) m,
    ];
    // Rows missing from the runtime mean something cleared the list under
    // an open archive; sealing what is left would empty the archive. Keep
    // the state as opened instead.
    final intact = ownedSites.length >= slice.siteIds.length;
    final sealed = handle.state.copyWith(
      cookies: {
        for (final m in ownedSites)
          m.siteId: [for (final c in m.cookies) c.toJson()],
      },
      sites: [for (final m in ownedSites) m.toArchiveJson()],
      // Renames, reorders and membership changes made while open persist.
      webspaces: [
        for (final w in _sites.webspaces)
          if (slice.webspaceIds.contains(w.id)) w.toJson(),
      ],
      appTierMembership: ArchiveMembershipEngine.record(_sites.webspaces,
          siteIds: slice.siteIds),
    );
    if (intact && !Archive.fits(sealed)) return false;
    _slices.remove(handle);
    if (intact) {
      handle.state.cookies
        ..clear()
        ..addAll(sealed.cookies);
      handle.state.sites
        ..clear()
        ..addAll(sealed.sites);
      handle.state.webspaces
        ..clear()
        ..addAll(sealed.webspaces);
      handle.state.appTierMembership
        ..clear()
        ..addAll(sealed.appTierMembership);
    } else {
      LogTag.archive.error(
          'close: ${slice.siteIds.length - ownedSites.length} archived sites '
          'missing from the runtime; sealed state left as opened');
    }
    // App-tier membership of the archived sites, sealed above, leaves the
    // runtime lists, so nothing names them once the archive is closed
    // (ARCH-001).
    ArchiveMembershipEngine.detach(_sites.webspaces, siteIds: slice.siteIds);
    if (intact) await _archive.save(handle);
    await _archive.close(handle);
    // Before the rows go, so the rebuild renders no orphan controller.
    for (final m in ownedSites) {
      m.disposeWebView();
    }
    // ARCH-007, best-effort: filesystems may retain freed blocks.
    for (final cid in slice.containerIds) {
      await containers.containerNative.deleteContainer(cid);
    }
    // A `ws-<siteId>` for an archived site means some path bound one without
    // the opaque id; it would otherwise name the site on disk until the next
    // cold-start sweep. Skipped for an id an app-tier site also holds (a
    // backup can bring one back), whose container is that site's own.
    if (_sites.useContainers) {
      final appTier = {
        for (final m in _sites.models)
          if (!m.isArchiveTier) m.siteId,
      };
      for (final sid in slice.siteIds) {
        if (!appTier.contains(sid)) await containers.onSiteDeleted(sid);
      }
    }
    // Defensive back-erasure of per-siteId app-tier state: the ARCH-006
    // overrides keep new writes out, and this catches entries written by
    // builds that predate them and by any path that forgets the gate.
    for (final sid in slice.siteIds) {
      await navStates.removeStatesForSite(sid);
      await cookieStore.saveCookiesForSite(sid, cookies: const []);
      await HtmlCacheService.instance.deleteCache(sid);
    }
    for (final m in ownedSites) {
      await FaviconUrlCache.invalidate(m.initUrl);
    }
    await proxyPasswords.mutate((draft) {
      for (final sid in slice.siteIds) {
        draft[sid] = null;
      }
    });
    await _host.commitSites(ArchiveClosed(
      siteIds: slice.siteIds,
      webspaceIds: slice.webspaceIds,
    ));
    return true;
  }

  /// Closes every open archive; false when one stayed open because it did
  /// not fit its slot (ARCH-011).
  Future<bool> closeAll() async {
    var all = true;
    for (final h in List<ArchiveHandle>.from(_slices.keys)) {
      if (!await close(h)) all = false;
    }
    return all;
  }

  /// "Close this archive" on one of its sites.
  Future<void> closeArchiveOf(WebViewModel site) async {
    final handle = archiveOf(site);
    if (handle == null) return;
    if (await close(handle)) {
      _host.toast((loc) => loc.homeArchiveClosed);
    } else {
      _host.toast((loc) => loc.homeArchiveFull);
    }
  }

  /// Moves app-tier [model] into the archive a passphrase names, offering to
  /// create one when none matches. Always asks, so the menu entry says
  /// nothing about whether an archive exists. The row keeps its position;
  /// its tier flips and its webview rebuilds against the opaque container.
  Future<void> moveIn(WebViewModel model) async {
    if (model.isArchiveTier) return;
    final passphrase = await _prompts.passphrase(PassphrasePurpose.moveSite);
    if (passphrase == null || passphrase.isEmpty || !_host.mounted) return;

    ArchiveHandle? target;
    try {
      target = await open(passphrase);
    } on StateError catch (e) {
      _host.toast((loc) => loc.homeCouldNotOpenArchive(e.message));
      return;
    }
    if (target == null) {
      if (!_host.mounted) return;
      if (!await _prompts.createArchive(PassphrasePurpose.moveSite)) return;
      try {
        target = await create(passphrase);
      } on StateError catch (e) {
        _host.toast((loc) => loc.homeCouldNotCreateArchive(e.message));
        return;
      }
    }
    if (!_host.mounted) return;

    final capturedCookies = await _host.captureCookies(model);
    // Before anything leaves the app tier (ARCH-011).
    final withSite = target.state.copyWith(
      sites: [...target.state.sites, model.toArchiveJson()],
      cookies: {
        ...target.state.cookies,
        model.siteId: [for (final c in capturedCookies) c.toJson()],
      },
      appTierMembership: ArchiveMembershipEngine.record(
        _sites.webspaces,
        siteIds: {model.siteId},
        existing: target.state.appTierMembership,
      ),
    );
    if (!Archive.fits(withSite)) {
      _host.toast((loc) => loc.homeArchiveFull);
      return;
    }
    // Derived before the flip so it is atomic: an archive-tier model with no
    // opaque id would rebuild against the cleartext `ws-<siteId>` container.
    final archiveContainerId =
        await _containerIdFor(target.key, siteId: model.siteId);

    // The tier flips before the app-tier stores drop the site (ARCH-001): a
    // concurrent persist filters on `!isArchiveTier` when it rebuilds the
    // app-tier cookie and password maps, so one that read the site before
    // the flip and landed after the clears would re-persist it.
    model.disposeWebView();
    model.isArchiveTier = true;
    model.archiveContainerId = archiveContainerId;
    model.setPendingArchiveCookies(capturedCookies);
    await cookieStore.saveCookiesForSite(model.siteId, cookies: const []);
    await proxyPasswords.mutate((draft) {
      draft[model.siteId] = null;
    });
    if (_sites.useContainers) await containers.onSiteDeleted(model.siteId);

    _slices[target]!.siteIds.add(model.siteId);
    _slices[target]!.containerIds.add(archiveContainerId);
    target.state.cookies[model.siteId] =
        capturedCookies.map((c) => c.toJson()).toList();
    await _host.commitSites(SiteArchived(model, into: target));
    _host.toast((loc) => loc.homeSiteMovedToArchive,
        duration: const Duration(seconds: 6));
  }

  /// The archived copy of [site] in [into], written once its references
  /// settled so it names no app-tier site, and before the app tier drops it.
  Future<void> recordIn(WebViewModel site,
      {required ArchiveHandle into}) async {
    into.state.sites.add(site.toArchiveJson());
    // Which app-tier collections the site came from: the runtime lists keep
    // it while the archive is open, and the persisted form strips it
    // (ARCH-001).
    into.state.appTierMembership
      ..clear()
      ..addAll(ArchiveMembershipEngine.record(
        _sites.webspaces,
        siteIds: {site.siteId},
        existing: into.state.appTierMembership,
      ));
    await _archive.save(into);
    await FaviconUrlCache.invalidate(site.initUrl);
  }

  /// [moveIn] reversed, while the site's archive is open.
  Future<void> moveOut(WebViewModel model) async {
    if (!model.isArchiveTier) return;
    final handle = archiveOf(model);
    if (handle == null) return;
    final slice = _slices[handle]!;

    final capturedCookies = await _host.captureCookies(model);
    final containerId = model.archiveContainerId;
    if (containerId != null) {
      await containers.containerNative.deleteContainer(containerId);
    }
    handle.state.sites.removeWhere((s) => s['siteId'] == model.siteId);
    handle.state.cookies.remove(model.siteId);
    ArchiveMembershipEngine.forget(handle.state.appTierMembership,
        siteId: model.siteId);
    slice.siteIds.remove(model.siteId);
    if (containerId != null) slice.containerIds.remove(containerId);
    await _archive.save(handle);

    // Back on the standard `ws-<siteId>` container.
    model.disposeWebView();
    model.isArchiveTier = false;
    model.archiveContainerId = null;
    model.cookies = capturedCookies;
    // TAB-018: back with the colour it kept in the archive, unless an
    // app-tier site took that colour meanwhile.
    model.containerColor = ContainerColorEngine.release(
      [model.containerColor],
      paletteSize: kContainerPaletteSize,
      held: [
        for (final m in _sites.models)
          if (!m.isArchiveTier && !identical(m, model)) m.containerColor,
      ],
    ).single;
    await _host.commitSites(SiteUnarchived(model));
    _host.toast((loc) => loc.homeSiteMovedOutOfArchive);
  }

  /// Settings entry point: open the archive a passphrase names, or offer to
  /// create one. The toasts never reveal whether other archives exist.
  Future<void> promptRestore() async {
    final passphrase =
        await _prompts.passphrase(PassphrasePurpose.openArchive);
    if (passphrase == null || passphrase.isEmpty || !_host.mounted) return;
    try {
      final handle = await open(passphrase);
      if (handle != null) {
        _host.toast((loc) => loc.homeArchiveOpened(
            handle.state.sites.length, handle.state.webspaces.length));
        return;
      }
      if (!_host.mounted) return;
      if (!await _prompts.createArchive(PassphrasePurpose.openArchive)) return;
      await create(passphrase);
      _host.toast((loc) => loc.homeNewArchiveCreated);
    } on StateError catch (e) {
      _host.toast((loc) => loc.homeCouldNotOpen(e.message));
    }
  }

  /// The open archives as opaque encrypted sections for an export, when the
  /// user includes them; null otherwise. Asked only while one is open, so a
  /// backup with none open is byte-identical to one made without the
  /// feature.
  Future<List<String>?> sectionsForExport() async {
    final open = _archive.openArchives;
    if (open.isEmpty) return null;
    if (!await _prompts.includeOpenArchives(open.length)) return null;
    return [for (final h in open) await _archive.exportSection(h)];
  }

  /// An import's encrypted sections, restored one passphrase at a time until
  /// none is left or the user cancels.
  Future<void> restoreSections(List<String> sections) async {
    var remaining = List<String>.from(sections);
    while (remaining.isNotEmpty && _host.mounted) {
      final passphrase =
          await _prompts.passphrase(PassphrasePurpose.restoreSections);
      if (passphrase == null || passphrase.isEmpty) break;
      final before = remaining.length;
      final unmatched =
          await _archive.importSections(passphrase, base64Sections: remaining);
      if (!_host.mounted) return;
      final restored = before - unmatched.length;
      remaining = unmatched;
      _host.toast((loc) => restored > 0
          ? loc.homeRestoredArchivedSections(restored)
          : loc.homeNoSectionMatchedPassphrase);
    }
  }
}
