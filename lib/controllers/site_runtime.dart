import 'dart:async';
import 'package:meta/meta.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';

import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/site_unload_engine.dart';
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
class SiteRuntime implements SiteModels {
  /// Written only by [apply].
  final List<WebViewModel> models = [];

  /// Sites with a built webview, least recently used first: activation
  /// re-adds its target at the end. Written by a table's step through
  /// [vars], and by [apply] and [retired] with a [Commit].
  @Modeled(ModelVar.loaded)
  Iterable<WebViewModel> get loaded => _loaded;
  final Set<WebViewModel> _loaded = {};

  /// The site on screen, or null on the webspace list.
  @Modeled(ModelVar.current)
  WebViewModel? get shown => _shown;
  WebViewModel? _shown;

  void _show(WebViewModel? site) {
    assert(
      site == null || models.any((m) => identical(m, site)),
      'the site on screen is one of the page\'s sites',
    );
    _shown = site;
  }

  /// The model's variables this runtime owns, as the model knows them, by
  /// id (CONT-012), and as the tables write them (`Mutable.over`): what a
  /// step declares it writes is all it can write. Read off the sites held
  /// on every access. Site to id is total but not one to one: after an
  /// import a departed site and its replacement share an id, and a read
  /// gives that id once, as the model has it. A write keeps the site a
  /// variable already holds under an id, the one whose webview it is, and
  /// otherwise names the listed site.
  late final RuntimeVars<SiteId> vars = RuntimeVars(
    loaded: Shared(
      ModelVar.loaded,
      read: () => _idsOf(_loaded),
      write: (to) {
        final held = [..._loaded];
        _loaded
          ..clear()
          ..addAll([for (final id in to) _site(id, held: held)]);
      },
    ),
    current: Shared(
      ModelVar.current,
      read: () => _idOf(_shown),
      write: (to) => _show(switch (to) {
        final id? => _site(id, held: [?_shown]),
        null => null,
      }),
    ),
    version: Shared(
      ModelVar.version,
      read: () => _version,
      write: (to) => _version = to,
    ),
    marker: Shared(
      ModelVar.marker,
      read: () => switch (_activating) {
        final m? => (target: _idOf(m.target)!, version: m.version),
        null => null,
      },
      write: (to) => _mark(switch (to) {
        final m? => (
          target: _site(m.target, held: [?_activating?.target]),
          version: m.version,
        ),
        null => null,
      }),
    ),
    nested: Shared(
      ModelVar.nested,
      read: () => _idOf(_nested),
      write: (to) {
        _nested = switch (to) {
          final id? => _site(id, held: [?_nested]),
          null => null,
        };
        _pin();
      },
    ),
    headless: Shared(
      ModelVar.headless,
      read: () => _idsOf(_headless),
      write: (to) {
        final held = [..._headless];
        _headless
          ..clear()
          ..addAll([for (final id in to) _site(id, held: held)]);
        _pin();
      },
    ),
    fore: Shared(ModelVar.fore, read: () => _fore, write: (to) => _fore = to),
  );

  /// Ids read off the sites outside the cells' `read:` closures, which
  /// name only the fields that hold each variable (`test/port_reads_test`).
  static SiteId? _idOf(WebViewModel? site) => site?.siteId;
  static Set<SiteId> _idsOf(Iterable<WebViewModel> sites) =>
      {for (final m in sites) m.siteId};

  /// The site [id] names for a write through [vars]: the one [held] has
  /// under it, else the listed one.
  WebViewModel _site(SiteId id, {required Iterable<WebViewModel> held}) {
    for (final m in held) {
      if (m.siteId == id) return m;
    }
    final listed = byId(id);
    assert(listed != null, 'an id names a site held under it or a listed one');
    return listed!;
  }

  /// The site [id] names: the listed one, else the one the nested screen,
  /// a wake's check or the activation in flight still holds after it left
  /// the list. The loaded sites and the one on screen are always listed
  /// ([apply]). Read off [_pinned], not the variables, so finding a site
  /// reads none of the model's state (`test/port_reads_test`); where a
  /// departed site and its replacement share an id, the replacement.
  @override
  WebViewModel siteOf(SiteId id) {
    final site = find(id);
    assert(site != null, 'an id names a listed site or one a variable holds');
    return site!;
  }

  /// [siteOf], null where no site is listed or held under [id].
  WebViewModel? find(SiteId id) => byId(id) ?? _pinned[id];

  /// Every site [siteOf] finds now, by id: what a flow keeps as it starts,
  /// so an id it names still finds its site once that left the list.
  Map<SiteId, WebViewModel> known() => {
    ..._pinned,
    for (final m in models) m.siteId: m,
  };

  /// The sites the nested screen, the wake's checks and the activation in
  /// flight hold, by id, kept by every write of those variables.
  final Map<SiteId, WebViewModel> _pinned = {};
  void _pin() => _pinned
    ..clear()
    ..addAll({
      for (final m in [?_nested, ..._headless, ?_activating?.target])
        m.siteId: m,
    });

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

  /// A site whose webview went outside the unload engine: its slot's
  /// identity changed. Named here so that is the only writer beside the
  /// tables and [apply].
  bool retired(WebViewModel site, {required Commit commit}) {
    final before = _loaded.length;
    _loaded.removeWhere((m) => m.modelKey == site.modelKey);
    final went = _loaded.length != before;
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
  @Modeled(ModelVar.current)
  int? get current => switch (_shown) {
    final s? => models.indexOfKey(s),
    null => null,
  };

  /// The rows of [loaded], in its order.
  @Modeled(ModelVar.loaded)
  Set<int> get loadedRows => {for (final m in loaded) models.indexOfKey(m)};

  /// Whether the site at [row] has a built webview.
  bool isLoadedAt(int row) =>
      row >= 0 && row < models.length && _loaded.hasKey(models[row]);

  /// Bumped by every activation and by every change that shifts positions,
  /// so an activation suspended across an await bails instead of resuming
  /// against another site.
  @Modeled(ModelVar.version)
  int get activationVersion => _version;
  int _version = 0;

  /// The activation still in flight: its target, which memory pressure must
  /// not pick (CONT-003), and the [activationVersion] it began at, which
  /// alone may clear it. Two activations of one site overlap on a double
  /// tap, and the superseded one must not unmark the other's. The target is
  /// the site itself, not its row, so a move cannot point it at another.
  @Modeled(ModelVar.marker)
  ActivationMarker<WebViewModel>? get activating => _activating;
  void _mark(ActivationMarker<WebViewModel>? value) {
    _activating = value;
    _pin();
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

  /// R8, SEC-044: a site joins the list only under an id no listed site
  /// holds, so a lookup by id names one site.
  void _assertUnlisted(Iterable<WebViewModel> joining) {
    assert(() {
      final ids = {for (final m in models) m.siteId};
      return joining.every((m) => ids.add(m.siteId));
    }(), 'a site joined the list under an id a listed site holds (SEC-044)');
  }

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
        assert(models.isEmpty, 'the startup load fills the empty list');
        models.addAll(sites);
      case SiteAdded(:final site, :final joins):
        _assertUnlisted([site]);
        models.add(site);
        for (final ws in webspaces) {
          if (!ws.isAll &&
              (joins?.contains(ws.id) ?? ws.id == selectedWebspaceId)) {
            ws.siteIds.add(site.siteId);
          }
        }
      case SiteRemoved(:final site):
        final row = models.indexOfKey(site);
        if (row >= 0) _drop([models.removeAt(row)]);
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
        _assertUnlisted(opened.sites);
        models.addAll(opened.sites);
        webspaces.addAll(spaces);
        ArchiveMembershipEngine.attach(
          webspaces,
          membership: appTierMembership,
        );
      case ArchiveClosed(sites: final leaving, :final webspaceIds):
        final closing = [
          for (final m in models)
            if (leaving.any((s) => identical(s, m))) m,
        ];
        models.removeWhere((m) => closing.any((c) => identical(c, m)));
        if (closing.isNotEmpty) _drop(closing);
        if (webspaceIds.contains(selectedWebspaceId)) {
          selectedWebspaceId = WebspaceId.all;
        }
        webspaces.removeWhere((w) => webspaceIds.contains(w.id));
    }
    for (final m in before) {
      if (!models.holdsObject(m)) m.disposeWebView(commit: commit);
    }
    // LIR-034: a tab follows a listed opener only, so one that left the list
    // leaves the tabs it opened following nothing, in the commit that takes
    // it; they keep the site they run as.
    for (final m in models) {
      for (final t in m.tabs) {
        if (t.openerSiteId case final o? when byId(o) == null) {
          SiteTab.openerCell.write(at: t, to: null, commit: commit);
        }
      }
    }
    final moved = before.length != models.length ||
        [
          for (var i = 0; i < before.length; i++)
            identical(before[i], models[i]),
        ].contains(false);
    if (moved) {
      commit.wrote(ModelVar.rows);
      if (before.any((m) => !models.hasKey(m))) commit.wrote(ModelVar.gone);
    }
    if (was.loaded.length != _loaded.length ||
        !was.loaded.containsAll(_loaded)) {
      commit.wrote(ModelVar.loaded);
    }
    if (!identical(was.shown, _shown)) commit.wrote(ModelVar.current);
    if (was.version != _version) commit.wrote(ModelVar.version);
    resolveWebspaceIndices();
    assert(
      _loaded.every(models.holdsObject) &&
          (_shown == null || models.holdsObject(_shown!)),
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
      if (!vars.isEvictable(m.siteId)) {
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
    final rows = [for (final m in among) models.indexOfKey(m)];
    return models[evictionOrder(rows, priorityOf: retentionPriority).first];
  }

  SlotIdentities slotIdentities() => SlotIdentities.of(models);
}
