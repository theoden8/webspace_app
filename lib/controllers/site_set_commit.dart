import 'dart:async';

import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/container_color_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_zone.dart';
import 'package:webspace/webspace_model.dart';

/// What a commit runs beside the lists, each the job of the controller
/// that owns it.
abstract interface class SiteSetCommitHost {
  bool get mounted;
  void rebuild();

  /// ARCH-010: the open archives seal before an import replaces the rows
  /// they were materialised into.
  Future<void> closeArchives();

  /// The archived copy of [change]'s site, once its references settled.
  Future<void> recordInArchive(SiteArchived change);

  void pruneLinkReferences();
  Future<void> reconcileLinkTabs();
  Future<void> closeIneligibleHostedTabs();

  /// The site on screen left the list, which leaves the screen empty.
  void screenEmptied();

  Future<void> saveSelectedWebspaceId();

  /// The Tor refcount follows the sites that name Tor.
  Future<void> syncTorHolders();
  Future<void> refreshRoutes({WebViewModel? active});
  Future<void> persistSites();
  Future<void> saveWebspaces();

  /// The background schedule and the audio session follow the sites.
  void backgroundSitesChanged();
  Future<void> sweepOrphans();
}

/// The one way the set of sites changes, and what runs after any change to
/// a site. The order is fixed; [SiteSetChange.effects] decides which steps
/// run, never in what order.
final class SiteSetCommit {
  SiteSetCommit(this._sites, {required SiteSetCommitHost host}) : _host = host;

  final SiteRuntime _sites;
  final SiteSetCommitHost _host;

  Future<void> commit(SiteSetChange change) async {
    final stage = this.stage(change);
    await stage.prepare();
    stage.land(commit: const Commit.unmodeled(Unmodeled.siteSet));
    await stage.follow();
  }

  /// [change] in the three parts a step table runs it in, so the lists
  /// move in a step's turn: what goes before, the move, what follows.
  SiteSetStage stage(SiteSetChange change) =>
      _FunnelStage(this, change: change);

  /// Before anything moves; false when the page went away meanwhile.
  Future<bool> _prepare(SiteSetChange change) async {
    // ARCH-010: open archives seal before an import replaces the rows they
    // were materialised into.
    switch (change) {
      case SitesReplaced():
        await _host.closeArchives();
        if (!_host.mounted) return false;
      case SitesEdited() ||
          SiteRemoved() ||
          SiteSettingsSaved() ||
          SiteSettingsClosed() ||
          SitesLoaded() ||
          SiteAdded() ||
          SitesMoved() ||
          ArchiveOpened() ||
          ArchiveClosed() ||
          SiteArchived() ||
          SiteUnarchived():
        break;
    }
    // Before the grid can build them: a webview's location shim takes the
    // zone as it is built, so one built first would run at the real zone.
    await resolveZones(change.arriving);
    return _host.mounted;
  }

  /// The lists move ([SiteRuntime.apply]) and the page redraws, in one
  /// turn.
  _Landed _land(SiteSetChange change, {required Commit commit}) {
    final landed = (
      shownBefore: _sites.shown,
      selectionBefore: _sites.selectedWebspaceId,
    );
    _sites.apply(change, commit: commit);
    _host.rebuild();
    return landed;
  }

  /// What follows the move, as [SiteSetChange.effects] asks.
  Future<void> _follow(SiteSetChange change, {required _Landed landed}) async {
    final effects = change.effects;
    // TAB-018: a site added since the last commit is drawn and written with
    // its colour.
    _assignContainerColors();
    if (effects.prunesReferences) _host.pruneLinkReferences();
    if (effects.followsOpeners) {
      await _host.reconcileLinkTabs();
      if (!_host.mounted) return;
    }
    if (effects.closesIneligibleTabs) {
      await _host.closeIneligibleHostedTabs();
      if (!_host.mounted) return;
    }
    if (change case final SiteArchived archived) {
      await _host.recordInArchive(archived);
      if (!_host.mounted) return;
    }
    if (landed.shownBefore case final shown?
        when !_sites.models.contains(shown)) {
      _host.screenEmptied();
    }
    if (_sites.selectedWebspaceId != landed.selectionBefore) {
      unawaited(_host.saveSelectedWebspaceId());
    }
    // Before the demo-mode bail in the writes: the refcount tracks runtime
    // intent, not persistence, and a demo session that pinned Tor up would
    // keep it up.
    await _host.syncTorHolders();
    unawaited(_host.refreshRoutes());
    if (effects.persists) await _host.persistSites();
    if (effects.savesWebspaces) await _host.saveWebspaces();
    if (effects.reschedulesBackground) _host.backgroundSitesChanged();
    if (effects.sweepsOrphans) await _host.sweepOrphans();
  }

  /// TAB-018: give every app-tier site without a container colour the least
  /// used one. Only app-tier sites count, so what the app-tier list stores
  /// never depends on an archive being open (ARCH-001).
  void _assignContainerColors() {
    final sites = [
      for (final m in _sites.models)
        if (!m.isArchiveTier) m,
    ];
    if (sites.every((m) => m.containerColor != null)) return;
    final given = ContainerColorEngine.assign(
      [for (final m in sites) m.containerColor],
      paletteSize: kContainerPaletteSize,
    );
    for (var i = 0; i < sites.length; i++) {
      sites[i].containerColor = given[i];
    }
  }
}

/// What the screen and the selection were before the lists moved.
typedef _Landed = ({WebViewModel? shownBefore, WebspaceId? selectionBefore});

/// One change to the set of sites, run in parts ([SiteSetCommit.stage]):
/// [prepare] may await, [land] moves the lists in the caller's [Commit],
/// and [follow] runs what the change asks after.
abstract interface class SiteSetStage {
  Future<void> prepare();
  void land({required Commit commit});
  Future<void> follow();
}

/// The funnel's own stage; a page that went away during [prepare] moves
/// nothing.
final class _FunnelStage implements SiteSetStage {
  _FunnelStage(this._funnel, {required SiteSetChange change})
      : _change = change;

  final SiteSetCommit _funnel;
  final SiteSetChange _change;
  bool _ready = false;
  _Landed? _landed;

  @override
  Future<void> prepare() async => _ready = await _funnel._prepare(_change);

  @override
  void land({required Commit commit}) {
    assert(_landed == null, 'a change lands once');
    if (_ready) _landed = _funnel._land(_change, commit: commit);
  }

  @override
  Future<void> follow() async {
    if (_landed case final landed?) {
      await _funnel._follow(_change, landed: landed);
    }
  }
}
