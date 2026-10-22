import 'dart:async';
import 'package:meta/meta.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// The page's sites and webspaces, and which sites are built and on screen.
///
/// The built sites and the one on screen are held as sites, so a change
/// that moves rows moves nothing here, and one that removes a site removes
/// it here too. Rows, which the page draws and an input names, are read
/// off them when asked for, and mean a site only until the next await;
/// [activationVersion] is what an activation suspended across one checks.
class SiteRuntime {
  /// Written only by [apply].
  final List<WebViewModel> models = [];

  /// Sites with a built webview, least recently used first: activation
  /// re-adds its target at the end. Written by a table's step through
  /// [vars], and by [apply] and [retired] with a [Commit].
  Iterable<WebViewModel> get loaded => _loaded;
  final Set<WebViewModel> _loaded = {};

  /// The site on screen, or null on the webspace list.
  WebViewModel? get shown => _shown;
  WebViewModel? _shown;

  void _show(WebViewModel? site) {
    assert(
      site == null || models.any((m) => identical(m, site)),
      'the site on screen is one of the page\'s sites',
    );
    _shown = site;
  }

  /// The model's variables this runtime owns, as the tables write them
  /// (`Mutable.over`): what a step declares it writes is all it can write.
  late final RuntimeVars<WebViewModel> vars = RuntimeVars(
    loaded: Shared.ofSet(_loaded, variable: ModelVar.loaded),
    current: Shared(ModelVar.current, read: () => _shown, write: _show),
    version: Shared(ModelVar.version, read: () => _version, write: (to) => _version = to),
    marker: Shared(ModelVar.marker, read: () => _activating, write: _mark),
    nested: Shared(
      ModelVar.nested,
      read: () => _nested,
      write: (to) => _nested = to,
    ),
    headless: Shared.ofSet(_headless, variable: ModelVar.headless),
    fore: Shared(ModelVar.fore, read: () => _fore, write: (to) => _fore = to),
  );

  /// The site whose nested screen is up: it runs as that site, beside the
  /// loaded ones. Written by the nested open's table steps.
  WebViewModel? get nested => _nested;
  WebViewModel? _nested;

  /// The sites a background wake checks in a headless webview: each runs
  /// as its site beside the loaded ones. Written by the wake's table steps.
  Set<WebViewModel> get headless => Set.unmodifiable(_headless);
  final Set<WebViewModel> _headless = {};

  /// Whether the app is on screen, as the wake's table last heard.
  bool get fore => _fore;
  bool _fore = true;

  /// A site whose webview went outside the unload engine: deleted, its
  /// trust revoked, or its slot's identity changed. Named here so those
  /// three are the only writers beside the tables and [apply].
  bool retired(WebViewModel site, {required Commit commit}) {
    final went = _loaded.remove(site);
    if (went) commit.wrote(ModelVar.loaded);
    return went;
  }

  /// The state an earlier session or input left, for a test to start from.
  @visibleForTesting
  void seed({Iterable<WebViewModel>? loaded, WebViewModel? shown}) {
    if (loaded != null) {
      _loaded
        ..clear()
        ..addAll(loaded);
    }
    _show(shown);
  }

  /// The row of [shown], or null on the webspace list.
  int? get current => switch (_shown) {
    final s? => models.indexOf(s),
    null => null,
  };

  /// The rows of [loaded], in its order.
  Set<int> get loadedRows => {for (final m in loaded) models.indexOf(m)};

  /// Whether the site at [row] has a built webview.
  bool isLoadedAt(int row) =>
      row >= 0 && row < models.length && _loaded.contains(models[row]);

  /// Bumped by every activation and by every change that shifts positions,
  /// so an activation suspended across an await bails instead of resuming
  /// against another site.
  int get activationVersion => _version;
  int _version = 0;

  /// The activation still in flight: its target, which memory pressure must
  /// not pick (CONT-003), and the [activationVersion] it began at, which
  /// alone may clear it. Two activations of one site overlap on a double
  /// tap, and the superseded one must not unmark the other's. The target is
  /// the site itself, not its row, so a move cannot point it at another.
  ActivationMarker<WebViewModel>? get activating => _activating;
  void _mark(ActivationMarker<WebViewModel>? value) {
    _activating = value;
    if (value == null) {
      _settled?.complete();
      _settled = null;
    }
  }

  ActivationMarker<WebViewModel>? _activating;
  Completer<void>? _settled;

  /// Completes once no activation is in flight.
  Future<void> activationSettled() => _activating == null
      ? Future<void>.value()
      : (_settled ??= Completer<void>()).future;

  /// Set once by the restore, before the sites are committed; a read before
  /// that is an error rather than a guess at the legacy engine.
  late final Isolation isolation;

  bool get useContainers => isolation is Containers;

  final List<Webspace> webspaces = [];
  WebspaceId? selectedWebspaceId;

  WebViewModel? byId(SiteId siteId) {
    for (final m in models) {
      if (m.siteId == siteId) return m;
    }
    return null;
  }

  bool isLoaded(WebViewModel model) => _loaded.contains(model);

  Set<SiteId> get siteIds => {for (final m in models) m.siteId};

  /// The sites whose stored state outlives the session: an incognito site's
  /// does not (#298).
  Set<SiteId> get nonIncognitoSiteIds => {
    for (final m in models)
      if (!m.incognito) m.siteId,
  };

  /// Every navigation-state key that should survive a sweep, for the sites in
  /// [siteIds]. State is per tab, so a site contributes one key per tab it
  /// still has: closing a tab makes its file an orphan, and deleting a site
  /// makes all of them orphans. The sweep speaks in sites; expanding a site to
  /// its keys belongs here, where the models are.
  Set<String> liveStateKeys(Set<SiteId> siteIds) => <String>{
    for (final m in models)
      if (siteIds.contains(m.siteId))
        for (final t in m.tabs) m.stateKeyForTab(t.id),
  };

  /// The positions the selected webspace shows, in display order.
  List<int> filteredIndices() => WebspaceSelectionEngine.filteredSiteIndices(
    selectedWebspaceId: selectedWebspaceId,
    webspaces: webspaces,
    siteCount: models.length,
  );

  /// Recomputes every webspace's positional view from its siteId membership.
  void resolveWebspaceIndices() => WebspaceSelectionEngine.resolveIndices(
    webspaces,
    siteIdsByPosition: [for (final m in models) m.siteId],
  );

  /// Applies [change] to the lists. A site that goes leaves [loaded] and
  /// [shown] with it and lets go of its webview, the site on screen going
  /// makes [shown] null, and a change that moves or removes rows bumps
  /// [activationVersion].
  void apply(SiteSetChange change, {required Commit commit}) {
    final before = [...models];
    final was = (
      loaded: {..._loaded},
      shown: _shown,
      version: _version,
    );
    switch (change) {
      case SitesEdited() ||
          SiteSettingsSaved() ||
          SiteSettingsClosed() ||
          SiteArchived() ||
          SiteUnarchived():
        break;
      case SitesLoaded(:final sites):
        models.addAll(sites);
      case SiteAdded(:final site, :final joins):
        models.add(site);
        for (final ws in webspaces) {
          if (!ws.isAll &&
              (joins?.contains(ws.id) ?? ws.id == selectedWebspaceId)) {
            ws.siteIds.add(site.siteId);
          }
        }
      case SiteRemoved(:final site):
        if (models.remove(site)) _drop([site]);
        for (final ws in webspaces) {
          ws.siteIds.remove(site.siteId);
        }
      case SitesMoved(:final from, :final to):
        models.insert(to, models.removeAt(from));
      case SitesReplaced(
        sites: final replacement,
        webspaces: final spaces,
        :final selectedWebspaceId,
      ):
        models
          ..clear()
          ..addAll(replacement);
        _loaded.clear();
        _shown = null;
        _version++;
        webspaces
          ..clear()
          ..addAll(spaces);
        this.selectedWebspaceId = selectedWebspaceId;
      case ArchiveOpened(
        sites: final opened,
        webspaces: final spaces,
        :final appTierMembership,
      ):
        models.addAll(opened);
        webspaces.addAll(spaces);
        ArchiveMembershipEngine.attach(
          webspaces,
          membership: appTierMembership,
        );
      case ArchiveClosed(:final siteIds, :final webspaceIds):
        final closing = [
          for (final m in models)
            if (siteIds.contains(m.siteId)) m,
        ];
        models.removeWhere(closing.contains);
        if (closing.isNotEmpty) _drop(closing);
        if (webspaceIds.contains(selectedWebspaceId)) {
          selectedWebspaceId = WebspaceId.all;
        }
        webspaces.removeWhere((w) => webspaceIds.contains(w.id));
    }
    for (final m in before) {
      if (!models.contains(m)) m.disposeWebView(commit: commit);
    }
    final moved = before.length != models.length ||
        [
          for (var i = 0; i < before.length; i++)
            identical(before[i], models[i]),
        ].contains(false);
    if (moved) {
      commit.wrote(ModelVar.rows);
      if (before.any((m) => !models.contains(m))) commit.wrote(ModelVar.gone);
    }
    if (was.loaded.length != _loaded.length ||
        !was.loaded.containsAll(_loaded)) {
      commit.wrote(ModelVar.loaded);
    }
    if (!identical(was.shown, _shown)) commit.wrote(ModelVar.current);
    if (was.version != _version) commit.wrote(ModelVar.version);
    resolveWebspaceIndices();
    assert(
      _loaded.every(models.contains) &&
          (_shown == null || models.contains(_shown)),
      'a site that left the list is still loaded or shown',
    );
  }

  /// [sites] left the list: they leave [loaded] and [shown] too, and an
  /// activation suspended meanwhile bails.
  void _drop(List<WebViewModel> sites) {
    _loaded.removeAll(sites);
    if (sites.any((s) => identical(s, _shown))) _shown = null;
    _version++;
  }

  /// How hard the site at [index] is to evict (PAUSE-006): the model's
  /// `Evictable` decides the two tiers that never are.
  SiteRetentionPriority retentionPriority(int index) {
    if (index >= 0 && index < models.length) {
      final m = models[index];
      if (!vars.isEvictable(m)) {
        return identical(m, _shown)
            ? SiteRetentionPriority.active
            : SiteRetentionPriority.activating;
      }
      // Background-audio sites share the notification retention tier: both
      // exist to keep running while other sites take the screen, so both
      // are evicted only after every ordinary site is gone.
      if (m.effectiveNotificationsEnabled ||
          m.effectiveBackgroundAudioEnabled) {
        return SiteRetentionPriority.notification;
      }
    }
    if (filteredIndices().contains(index)) {
      return SiteRetentionPriority.webspace;
    }
    return SiteRetentionPriority.loaded;
  }

  /// Of [among], evictable sites in least recently used order, the one an
  /// eviction takes first: the lowest retention priority, oldest first.
  WebViewModel firstToEvict(Iterable<WebViewModel> among) {
    final rows = [for (final m in among) models.indexOf(m)];
    return models[evictionOrder(rows, priorityOf: retentionPriority).first];
  }

  /// What each slot runs as, index-aligned with [models] (LIR-024): the host
  /// of its active tab, or the site itself. [except] keeps one slot as the
  /// site, for a nested screen that runs as that site.
  List<WebViewModel> slotIdentities({int? except}) => [
    for (var i = 0; i < models.length; i++)
      i == except ? models[i] : models[i].runningIdentity,
  ];
}
