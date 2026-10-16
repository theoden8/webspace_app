import 'dart:typed_data';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/activation_step.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/html_cache_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/step_flow.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/tab_leaves.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/utils/concurrency.dart';
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

  /// The next frame drawn, which builds the loaded sites' webviews and
  /// unmounts the rest.
  Future<void> endOfFrame();

  /// [change] in the parts the close's steps run it in, so the lists move
  /// in the drop's turn (`SiteSetCommit.stage`).
  SiteSetStage stageSites(SiteSetChange change);
}

/// Which rows of the lists belong to one open archive, so a close removes
/// exactly those.
class _ArchiveSlice {
  _ArchiveSlice({
    required this.siteIds,
    required this.webspaceIds,
    required this.containerKeys,
  });
  final Set<SiteId> siteIds;
  final Set<WebspaceId> webspaceIds;

  /// Opaque container keys of the archive's sites, deleted on close so no
  /// archive-tier container directory outlives it (ARCH-007).
  final Set<ContainerKey> containerKeys;
}

/// Passphrase-gated archives on the page (spec `archive`): opening one puts
/// its sites in the lists marked archive-tier, closing seals them back.
class ArchiveController {
  ArchiveController(
    this._sites, {
    required ArchiveHost host,
    required ArchivePrompts prompts,
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
  final CookieSecureStorage cookieStore;
  final ProxyPasswordSecureStorage proxyPasswords;
  final WebViewStateStorage navStates;

  /// Its slot pool initialises on first open or create, so a user who never
  /// touches the feature pays no secure-storage write at startup (ARCH-001).
  final Archive _archive;

  final Map<ArchiveHandle, _ArchiveSlice> _slices = {};

  /// Every change to which archives are open and to what they hold, one at
  /// a time: a close that ran between a move's steps sealed a state the move
  /// then changed, or left a site on the archive tier with no archive to
  /// hold it. Prompts run outside it.
  final SerialQueue _ops = SerialQueue('archiveOps');

  bool get anyOpen => _slices.isNotEmpty;

  /// The open archive [m] belongs to, or null for an app-tier site.
  ArchiveHandle? archiveOf(WebViewModel m) => _slices.entries
      .where((e) => e.value.siteIds.contains(m.siteId))
      .firstOrNull
      ?.key;

  /// The handle for [passphrase] with its sites in the lists, or null when
  /// none matches. Done before returning: a caller writes into the handle
  /// and its slice right after.
  Future<ArchiveHandle?> open(String passphrase) =>
      _ops.run(() => _openHeld(passphrase));

  Future<ArchiveHandle> create(String passphrase) =>
      _ops.run(() => _createHeld(passphrase));

  Future<ArchiveHandle?> _openHeld(String passphrase) async {
    assert(_ops.isHeld, 'an archive opened outside its turn');
    final handle = await _archive.tryOpen(passphrase);
    if (handle == null) return null;
    if (_slices.containsKey(handle)) return handle;
    await _materialise(handle);
    return handle;
  }

  Future<ArchiveHandle> _createHeld(String passphrase) async {
    assert(_ops.isHeld, 'an archive created outside its turn');
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
      model.archiveContainerKey =
          await _containerKeyFor(handle.key, siteId: model.siteId);
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
      containerKeys: {for (final m in sites) m.archiveContainerKey!},
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
  static Future<ContainerKey> _containerKeyFor(
    Uint8List archiveKey, {
    required SiteId siteId,
  }) async {
    final mac = await ArchiveCrypto.hmac(archiveKey, info: 'container:$siteId');
    final bd = ByteData.view(mac.buffer, mac.offsetInBytes);
    final v1 =
        (bd.getUint16(0) * 0x100000000) + bd.getUint32(2); // 48-bit group
    final v2 = bd.getUint32(6);
    return ContainerKey.named(
        '${v1.toRadixString(36)}-${v2.toRadixString(36)}');
  }

  /// Seals [handle]: its sites, cookies and collections back into its state,
  /// saved; the key zeroed; its containers and every per-site trace outside
  /// the archive gone; its rows out of the lists. False when the sealed
  /// state does not fit its slot (ARCH-011): nothing changes and the
  /// archive stays open.
  Future<bool> close(ArchiveHandle handle) =>
      _ops.run(() => _closeHeld(handle));

  Future<bool> _closeHeld(ArchiveHandle handle) async {
    assert(_ops.isHeld, 'an archive closed outside its turn');
    final slice = _slices[handle];
    if (slice == null) return true;
    final flow = CloseFlow._(this, handle: handle, slice: slice);
    final c = StepContext(flow);
    final table = closeTable;
    final next = table.runInput(c, from: ClosePlace.close);
    _closing = true;
    try {
      await table.run(c, from: next);
    } finally {
      _closing = false;
    }
    return flow.closed;
  }

  /// Whether a close is under way: the model's `"close" \in Kinds`.
  bool _closing = false;

  /// The table a close runs from, printed into the model (ARCH-007,
  /// ARCH-014).
  static StepTable<CloseFlow, ClosePlace> get closeTable => _closeTable;

  /// Closes every open archive; false when one stayed open because it did
  /// not fit its slot (ARCH-011).
  Future<bool> closeAll() => _ops.run(() async {
        var all = true;
        for (final h in List<ArchiveHandle>.from(_slices.keys)) {
          if (!await _closeHeld(h)) all = false;
        }
        return all;
      });

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

    // Found, the move runs in the turn that opened it; not found, the
    // create prompt runs outside the turns, and create and move share one.
    final ArchiveHandle? found;
    try {
      found = await _ops.run(() async {
        final target = await _openHeld(passphrase);
        if (target != null) await _moveInHeld(model, into: target);
        return target;
      });
    } on StateError catch (e) {
      _host.toast((loc) => loc.homeCouldNotOpenArchive(e.message));
      return;
    }
    if (found != null) return;
    if (!_host.mounted) return;
    if (!await _prompts.createArchive(PassphrasePurpose.moveSite)) return;
    try {
      await _ops.run(() async {
        final target = await _createHeld(passphrase);
        await _moveInHeld(model, into: target);
      });
    } on StateError catch (e) {
      _host.toast((loc) => loc.homeCouldNotCreateArchive(e.message));
    }
  }

  Future<void> _moveInHeld(WebViewModel model,
      {required ArchiveHandle into}) async {
    assert(_ops.isHeld, 'a site moved into an archive outside its turn');
    final target = into;
    // A turn since the prompt: the site may have moved or gone meanwhile.
    if (!_host.mounted || model.isArchiveTier || !_sites.models.contains(model)) {
      return;
    }

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
    final archiveContainerKey =
        await _containerKeyFor(target.key, siteId: model.siteId);

    // The tier flips before the app-tier stores drop the site (ARCH-001): a
    // concurrent persist filters on `!isArchiveTier` when it rebuilds the
    // app-tier cookie and password maps, so one that read the site before
    // the flip and landed after the clears would re-persist it.
    model.disposeWebView(commit: const Commit.unmodeled(Unmodeled.archiveMove));
    model.isArchiveTier = true;
    model.archiveContainerKey = archiveContainerKey;
    model.setPendingArchiveCookies(capturedCookies);
    await cookieStore.saveCookiesForSite(model.siteId, cookies: const []);
    await proxyPasswords.mutate((draft) {
      draft[ProxyPasswordKey.site(model.siteId)] = null;
    });
    if (_sites.isolation case Containers(:final engine)) {
      await engine.onSiteDeleted(ContainerKey.ofSite(model.siteId));
    }

    _slices[target]!.siteIds.add(model.siteId);
    _slices[target]!.containerKeys.add(archiveContainerKey);
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
    assert(_ops.isHeld, 'an archived copy written outside the move\'s turn');
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
  Future<void> moveOut(WebViewModel model) => _ops.run(() async {
        if (!_host.mounted) return;
        await _moveOutHeld(model);
      });

  Future<void> _moveOutHeld(WebViewModel model) async {
    assert(_ops.isHeld, 'a site moved out of an archive outside its turn');
    if (!model.isArchiveTier) return;
    final handle = archiveOf(model);
    if (handle == null) return;
    final slice = _slices[handle]!;

    final capturedCookies = await _host.captureCookies(model);
    final containerKey = model.archiveContainerKey;
    if ((containerKey, _sites.isolation)
        case (final key?, Containers(:final engine))) {
      await engine.containerNative.deleteContainer(key);
    }
    handle.state.sites.removeWhere((s) => s['siteId'] == model.siteId);
    handle.state.cookies.remove(model.siteId);
    ArchiveMembershipEngine.forget(handle.state.appTierMembership,
        siteId: model.siteId);
    slice.siteIds.remove(model.siteId);
    if (containerKey != null) slice.containerKeys.remove(containerKey);
    await _archive.save(handle);

    // Back on the standard `ws-<siteId>` container.
    model.disposeWebView(commit: const Commit.unmodeled(Unmodeled.archiveMove));
    model.isArchiveTier = false;
    model.archiveContainerKey = null;
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
    if (_archive.openArchives.isEmpty) return null;
    if (!await _prompts.includeOpenArchives(_archive.openArchives.length)) {
      return null;
    }
    // Read in a turn: a close since the prompt leaves nothing to export.
    return _ops.run(() async => [
          for (final h in _archive.openArchives)
            await _archive.exportSection(h),
        ]);
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
      final unmatched = await _ops.run(() =>
          _archive.importSections(passphrase, base64Sections: remaining));
      if (!_host.mounted) return;
      final restored = before - unmatched.length;
      remaining = unmatched;
      _host.toast((loc) => restored > 0
          ? loc.homeRestoredArchivedSections(restored)
          : loc.homeNoSectionMatchedPassphrase);
    }
  }
}

/// The places a close waits at, as `activation.tla` names them: its input,
/// the sealed state's save, the sites leaving the lists, the frame that
/// takes their webviews, the containers' deletes, the traces' erasure.
enum ClosePlace { close, cSeal, cDrop, cFrame, cDelete, cErase, done }

/// One close as its table runs it: the archive, what of it is on the page,
/// and the state sealed from that.
final class CloseFlow {
  CloseFlow._(this.controller, {required this.handle, required this.slice});

  final ArchiveController controller;
  final ArchiveHandle handle;
  final _ArchiveSlice slice;

  SiteRuntime get _sites => controller._sites;

  late final List<WebViewModel> owned = [
    for (final m in _sites.models)
      if (slice.siteIds.contains(m.siteId)) m,
  ];

  /// Rows missing from the runtime mean something cleared the list under
  /// an open archive; sealing what is left would empty the archive. The
  /// state is kept as opened instead.
  late final bool intact = owned.length >= slice.siteIds.length;

  late final ArchiveState sealed = handle.state.copyWith(
    cookies: {
      for (final m in owned) m.siteId: [for (final c in m.cookies) c.toJson()],
    },
    sites: [for (final m in owned) m.toArchiveJson()],
    // Renames, reorders and membership changes made while open persist.
    webspaces: [
      for (final w in _sites.webspaces)
        if (slice.webspaceIds.contains(w.id)) w.toJson(),
    ],
    appTierMembership: ArchiveMembershipEngine.record(
      _sites.webspaces,
      siteIds: slice.siteIds,
    ),
  );

  /// The close ran to its end: false when the sealed state does not fit
  /// its slot (ARCH-011), which changes nothing.
  bool closed = false;

  /// The archive leaves the open ones and takes its sealed state; the app
  /// tier's lists stop naming its sites (ARCH-001).
  void seal() {
    controller._slices.remove(handle);
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
        'close: ${slice.siteIds.length - owned.length} archived sites '
        'missing from the runtime; sealed state left as opened',
      );
    }
    ArchiveMembershipEngine.detach(_sites.webspaces, siteIds: slice.siteIds);
  }

  Future<void> save() async {
    if (intact) await controller._archive.save(handle);
    await controller._archive.close(handle);
  }

  /// The sites leave the lists, and so the loaded set and the screen, and
  /// let go of their webviews, which the next frame unmounts, in the page's
  /// own commit, which supersedes an activation in flight.
  late final SiteSetStage _drop = controller._host.stageSites(
    ArchiveClosed(siteIds: slice.siteIds, webspaceIds: slice.webspaceIds),
  );

  /// What follows the commit, then the frame: a container a mounted
  /// webview still binds is not deleted (LIR-023), so the deletes wait for
  /// the frame that unmounts the sites' webviews.
  Future<void> frame() async {
    await _drop.follow();
    await controller._host.endOfFrame();
  }

  /// ARCH-007, best-effort: filesystems may retain freed blocks.
  Future<void> deleteContainers() async {
    if (_sites.isolation case Containers(:final engine)) {
      for (final key in slice.containerKeys) {
        await engine.containerNative.deleteContainer(key);
      }
    }
  }

  /// A `ws-<siteId>` for an archived site means some path bound one
  /// without the opaque id; it would otherwise name the site on disk until
  /// the next cold-start sweep. Skipped for an id an app-tier site also
  /// holds (a backup can bring one back), whose container is that site's
  /// own. Then a defensive back-erasure of per-siteId app-tier state: the
  /// ARCH-006 overrides keep new writes out, and this catches entries
  /// written by builds that predate them and by any path that forgets the
  /// gate.
  Future<void> erase() async {
    if (_sites.isolation case Containers(:final engine)) {
      final appTier = {
        for (final m in _sites.models)
          if (!m.isArchiveTier) m.siteId,
      };
      for (final sid in slice.siteIds) {
        if (!appTier.contains(sid)) {
          await engine.onSiteDeleted(ContainerKey.ofSite(sid));
        }
      }
    }
    for (final sid in slice.siteIds) {
      await controller.navStates.removeStatesForSite(sid);
      await controller.cookieStore.saveCookiesForSite(sid, cookies: const []);
      await HtmlCacheService.instance.deleteCache(sid);
    }
    for (final m in owned) {
      await FaviconUrlCache.invalidate(m.initUrl);
    }
    await controller.proxyPasswords.mutate((draft) {
      for (final sid in slice.siteIds) {
        draft[ProxyPasswordKey.site(sid)] = null;
      }
    });
  }
}

final _closeKind = Field<FlowKind, CloseFlow>(FlowField.kind);

/// The archive's sites on the page, the model's `Archive`.
final _archiveSites = Constant<Iterable<WebViewModel>, CloseFlow>(
  ModelConst.archive,
  read: (w) => w.owned,
).value;

/// What the close asks of its archive before it starts: whether it is
/// still open, whether a close already runs, whether its sealed slice no
/// longer fits.
final _closeAsk = Port<CloseAsk, CloseFlow>(
  'ask',
  reads: {ModelVar.gone, ModelVar.fl},
  changes: const {},
  of: (w) => (
    open: () => w.controller._slices.containsKey(w.handle),
    running: () => w.controller._closing,
    tooBig: () => w.intact && !Archive.fits(w.sealed),
  ),
);

/// What the close's calls and marks do, each declared with what it changes
/// in the model: the commit's drop, the frame, the containers' delete; the
/// seal, its save and the erase change nothing the model holds.
final _closeDropPort = Port<SiteSetStage, CloseFlow>(
  'drop',
  reads: const {},
  changes: {
    ModelVar.gone,
    ModelVar.loaded,
    ModelVar.current,
    ModelVar.version,
    ModelVar.built,
    ModelVar.hist,
  },
  of: (w) => w._drop,
);
final _closeFramePort = Port<Future<void> Function(), CloseFlow>(
  'frame',
  reads: const {},
  changes: {ModelVar.views},
  of: (w) => w.frame,
);
final _closeDeletePort = Port<Future<void> Function(), CloseFlow>(
  'deleteContainers',
  reads: const {},
  changes: {ModelVar.boxes},
  of: (w) => w.deleteContainers,
);
final _closeSealPort = Port<CloseSeal, CloseFlow>(
  'seal',
  reads: const {},
  changes: const {},
  of: (w) => (
    seal: w.seal,
    save: w.save,
    erase: w.erase,
    closed: () => w.closed = true,
  ),
);

final _closeOpen = Expr.op<bool, CloseFlow>(
  r'Archive # {} /\ Archive \cap gone = {}',
  run: (c) => _closeAsk.from(c).open(),
  reads: const Reads(vars: {ModelVar.gone}),
  needs: const {(of: ModelConst.archive, set: true)},
);
final _closeRunning = Expr.inFlight<CloseFlow>(
  FlowKind.close,
  run: (c) => _closeAsk.from(c).running(),
);
final _closeTooBig = Expr.op<bool, CloseFlow>(
  'FALSE',
  run: (c) => _closeAsk.from(c).tooBig(),
  reads: Reads.none,
);

final _closeLoaded = Mutable<Iterable<WebViewModel>, CloseFlow>.over(
  ModelVar.loaded,
  of: (w) => w._sites.vars.loaded,
);
final _closeCurrent = Mutable<WebViewModel?, CloseFlow>.over(
  ModelVar.current,
  of: (w) => w._sites.vars.current,
);
final _closeVersion = Mutable<int, CloseFlow>.over(
  ModelVar.version,
  of: (w) => w._sites.vars.version,
);
final _closeGone = Mutable<Iterable<WebViewModel>, CloseFlow>.remote(
  ModelVar.gone,
);
final _closeViews = Mutable<Iterable<WebViewModel>, CloseFlow>.remote(
  ModelVar.views,
);
final _closeBoxes = Mutable<Iterable<WebViewModel>, CloseFlow>.remote(
  ModelVar.boxes,
);
final _closeNoSite = Expr.constant<WebViewModel?, CloseFlow>(null, tla: '0');

final _closeDone = GoTo<CloseFlow, ClosePlace>(to(ClosePlace.done));

/// The traces outside the archive erased: the close has run.
final _closeErase = Await<CloseFlow, ClosePlace>(
  ActivationStep.closeEraseReply,
  at: ClosePlace.cErase,
  holds: null,
  call: Call.on(_closeSealPort, run: (c) => c.api.erase(), writes: const []),
  decide: Ends(
    StepOutcome.none,
    does: [Note((c) => _closeSealPort.from(c).closed())],
    next: _closeDone,
  ),
);

/// The containers no mounted webview binds are deleted.
final _closeDelete = Await<CloseFlow, ClosePlace>(
  ActivationStep.closeDeleteReply,
  at: ClosePlace.cDelete,
  holds: null,
  call: Call.on(
    _closeDeletePort,
    run: (c) => c.api(),
    writes: [
      _closeBoxes.becomes(
        _closeBoxes.value.less(_archiveSites.less(_closeViews.value)),
      ),
    ],
  ),
  decide: Ends(StepOutcome.none, next: _closeErase),
);

/// The frame unmounts the webviews of sites no longer loaded.
final _closeFrame = Await<CloseFlow, ClosePlace>(
  ActivationStep.closeFrameReply,
  at: ClosePlace.cFrame,
  holds: null,
  call: Call.on(
    _closeFramePort,
    run: (c) => c.api(),
    writes: [_closeViews.becomes(_closeViews.value.less(_archiveSites))],
  ),
  decide: Ends(StepOutcome.none, next: _closeDelete),
);

/// The page's commit takes the archive's sites off the lists, the loaded
/// set and the screen, lets go of their webviews, and bumps the version.
final _closeDrop = Await<CloseFlow, ClosePlace>(
  ActivationStep.closeDropReply,
  at: ClosePlace.cDrop,
  holds: null,
  call: Call.on(
    _closeDropPort,
    run: (c) => c.api.prepare(),
    then: (c) => _closeDropPort.from(c).land(commit: c.commit),
    writes: [
      _closeGone.becomes(_closeGone.value.union(_archiveSites)),
      _closeLoaded.becomes(_closeLoaded.value.less(_archiveSites)),
      _closeCurrent.becomes(
        Expr.choose(
          when: _archiveSites.has(_closeCurrent.value),
          then: _closeNoSite,
          otherwise: _closeCurrent.value,
        ),
      ),
      _closeVersion.becomes(_closeVersion.value.plus(1)),
      ...webViewsGone(_archiveSites),
    ],
  ),
  decide: Ends(StepOutcome.none, next: _closeFrame),
);

final _closeSeal = Await<CloseFlow, ClosePlace>(
  ActivationStep.closeSealReply,
  at: ClosePlace.cSeal,
  holds: null,
  call: Call.on(_closeSealPort, run: (c) => c.api.save(), writes: const []),
  decide: Ends(StepOutcome.none, next: _closeDrop),
);

/// The user closes an open archive (ARCH-007, ARCH-014): its sites leave
/// the lists before any container is touched, and its containers wait for
/// the frame that unmounts their webviews.
final _closeFlow = FlowInput<CloseFlow, ClosePlace>(
  ActivationStep.closeArchive,
  at: ClosePlace.close,
  enabled: _closeOpen & ~_closeRunning,
  decide: When(
    _closeTooBig,
    then: Ends(StepOutcome.skip, next: _closeDone),
    otherwise: Ends(
      StepOutcome.go,
      does: [
        _closeKind.becomes(Expr.constant(FlowKind.close)),
        Note((c) => _closeSealPort.from(c).seal()),
      ],
      next: _closeSeal,
    ),
  ),
);

final _closeSteps = _closeFlow.steps;

/// What a close asks before it starts ([_closeAsk]).
typedef CloseAsk = ({
  bool Function() open,
  bool Function() running,
  bool Function() tooBig,
});

/// The close's marks and the calls that change nothing the model holds
/// ([_closeSealPort]).
typedef CloseSeal = ({
  void Function() seal,
  Future<void> Function() save,
  Future<void> Function() erase,
  void Function() closed,
});

final StepTable<CloseFlow, ClosePlace> _closeTable = StepTable(
  ClosePlace.values,
  ending: {ClosePlace.done},
  vars: [_closeLoaded, _closeCurrent, _closeVersion],
  at: (place) => switch (place) {
    ClosePlace.close ||
    ClosePlace.cSeal ||
    ClosePlace.cDrop ||
    ClosePlace.cFrame ||
    ClosePlace.cDelete ||
    ClosePlace.cErase => _closeSteps[place]!,
    ClosePlace.done => const Leaves(),
  },
);
