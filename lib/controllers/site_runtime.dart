import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/services/site_lifecycle_engine.dart';
import 'package:webspace/services/site_retention_priority.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// The page's sites and webspaces, and which sites are built and on screen.
///
/// Positions index [models]. Every controller of the page reads the same
/// instance, so a position means the same site to all of them at a given
/// moment; an await is where it can stop meaning that, which is what
/// [activationVersion] is for.
class SiteRuntime {
  /// Written only by [apply].
  final List<WebViewModel> models = [];

  /// Sites with a built webview, least recently used first: activation
  /// re-adds its target at the end.
  final Set<int> loaded = {};

  /// The site on screen, or null on the webspace list.
  int? current;

  /// Bumped by every activation and by every change that shifts positions,
  /// so an activation suspended across an await bails instead of resuming
  /// against another site.
  int activationVersion = 0;

  /// The target of an activation still in flight, which memory pressure
  /// must not pick (PAUSE-016).
  int? activating;

  /// Native per-site containers, resolved once at startup; false runs the
  /// legacy shared-jar engine.
  bool useContainers = false;

  final List<Webspace> webspaces = [];
  String? selectedWebspaceId;

  /// The site on screen, or null.
  WebViewModel? get shown {
    final i = current;
    return i != null && i >= 0 && i < models.length ? models[i] : null;
  }

  WebViewModel? byId(String siteId) {
    for (final m in models) {
      if (m.siteId == siteId) return m;
    }
    return null;
  }

  bool isLoaded(WebViewModel model) => loaded.contains(models.indexOf(model));

  /// The positions the selected webspace shows, in display order.
  List<int> filteredIndices() => WebspaceSelectionEngine.filteredSiteIndices(
        selectedWebspaceId: selectedWebspaceId,
        webspaces: webspaces,
        siteCount: models.length,
      );

  /// Recomputes every webspace's positional view from its siteId membership.
  void resolveWebspaceIndices() => WebspaceSelectionEngine.resolveIndices(
      webspaces, siteIdsByPosition: [for (final m in models) m.siteId]);

  /// Applies [change] to the lists. A row that moves or goes takes [loaded]
  /// and [current] with it through [SiteLifecycleEngine]'s patches, in
  /// [loaded]'s order, and bumps [activationVersion]; the site on screen
  /// going makes [current] null.
  void apply(SiteSetChange change) {
    switch (change) {
      case SitesEdited() ||
            SiteSettingsSaved() ||
            SiteSettingsClosed() ||
            SiteArchived() ||
            SiteUnarchived():
        break;
      case SitesLoaded(:final sites):
        models.addAll(sites);
      case SiteAdded(:final site):
        models.add(site);
        for (final ws in webspaces) {
          if (!ws.isAll && ws.id == selectedWebspaceId) {
            ws.siteIds.add(site.siteId);
          }
        }
      case SiteRemoved(:final site):
        final at = models.indexOf(site);
        if (at >= 0) _removeAt(at);
        for (final ws in webspaces) {
          ws.siteIds.remove(site.siteId);
        }
      case SitesMoved(:final from, :final to):
        final patch = SiteLifecycleEngine.computeReorderPatch(
          oldIndex: from,
          newIndex: to,
          loadedIndices: loaded,
          currentIndex: current,
        );
        models.insert(to, models.removeAt(from));
        _repoint(patch.newLoadedIndices, newCurrent: patch.newCurrentIndex);
      case SitesReplaced(
          sites: final replacement,
          webspaces: final spaces,
          :final selectedWebspaceId,
        ):
        models
          ..clear()
          ..addAll(replacement);
        _repoint(const {}, newCurrent: null);
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
        ArchiveMembershipEngine.attach(webspaces,
            membership: appTierMembership);
      case ArchiveClosed(:final siteIds, :final webspaceIds):
        // Highest first, so each patch reads positions the earlier ones left.
        for (var i = models.length - 1; i >= 0; i--) {
          if (siteIds.contains(models[i].siteId)) _removeAt(i);
        }
        if (webspaceIds.contains(selectedWebspaceId)) {
          selectedWebspaceId = kAllWebspaceId;
        }
        webspaces.removeWhere((w) => webspaceIds.contains(w.id));
    }
    resolveWebspaceIndices();
  }

  void _removeAt(int index) {
    final patch = SiteLifecycleEngine.computeDeletionPatch(
      deletedIndex: index,
      siteCountBeforeRemoval: models.length,
      loadedIndices: loaded,
      webspaces: const [],
      currentIndex: current,
    );
    models.removeAt(index);
    _repoint(patch.newLoadedIndices, newCurrent: patch.newCurrentIndex);
  }

  void _repoint(Set<int> newLoaded, {required int? newCurrent}) {
    loaded
      ..clear()
      ..addAll(newLoaded);
    current = newCurrent;
    activationVersion++;
  }

  /// How hard the site at [index] is to evict (PAUSE-006).
  SiteRetentionPriority retentionPriority(int index) {
    if (index == current) return SiteRetentionPriority.active;
    if (index == activating) return SiteRetentionPriority.activating;
    if (index >= 0 && index < models.length) {
      final m = models[index];
      // Background-audio sites share the notification retention tier: both
      // exist to keep running while other sites take the screen, so both
      // are evicted only after every ordinary site is gone.
      if (m.effectiveNotificationsEnabled || m.effectiveBackgroundAudioEnabled) {
        return SiteRetentionPriority.notification;
      }
    }
    if (filteredIndices().contains(index)) return SiteRetentionPriority.webspace;
    return SiteRetentionPriority.loaded;
  }

  /// What each slot runs as, index-aligned with [models] (LIR-024): the host
  /// of its active tab, or the site itself. [except] keeps one slot as the
  /// site, for a nested screen that runs as that site.
  List<WebViewModel> slotIdentities({int? except}) => [
        for (var i = 0; i < models.length; i++)
          i == except ? models[i] : models[i].runningIdentity,
      ];
}
