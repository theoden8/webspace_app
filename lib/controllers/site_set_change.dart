import 'package:webspace/services/archive.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

/// What the page runs after a [SiteSetChange], beyond what it runs after
/// every one: container colours, the webspace positions, the Tor refcount
/// and exit pin, the proxy routes, and going home when the site on screen
/// is gone.
typedef SiteSetEffects = ({
  /// Write the app-tier site list. Archive rows are filtered out (ARCH-001).
  bool persists,

  bool savesWebspaces,

  /// LIR-017 / LIR-031: drop outbound and search references that name a
  /// site gone or on the far side of the archive boundary.
  bool prunesReferences,

  /// LIR-034: link tabs follow their opener's routing switch.
  bool followsOpeners,

  /// LIR-023: hosted tabs whose host is gone or may no longer host close.
  bool closesIneligibleTabs,

  /// NOTIF-005 / BGAUDIO-003: the background schedule and audio session
  /// follow the loaded sites.
  bool reschedulesBackground,

  /// Storage of sites no longer in the list is swept.
  bool sweepsOrphans,
});

/// One change to the set of sites, or to what the page must reconcile
/// after one. `_commitSites` is the only way a change is made, and its
/// order is fixed; what each kind needs is decided once, in [effects].
sealed class SiteSetChange {
  const SiteSetChange();

  SiteSetEffects get effects => switch (this) {
        SitesEdited() => (
            persists: true,
            savesWebspaces: false,
            prunesReferences: false,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        SiteSettingsSaved() => (
            persists: true,
            savesWebspaces: false,
            prunesReferences: false,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: true,
            sweepsOrphans: false,
          ),
        // The routing switch may have flipped while the screen was open.
        SiteSettingsClosed() => (
            persists: true,
            savesWebspaces: false,
            prunesReferences: false,
            followsOpeners: true,
            closesIneligibleTabs: true,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        // The load-time migration is written after first paint, not here.
        SitesLoaded() => (
            persists: false,
            savesWebspaces: false,
            prunesReferences: true,
            followsOpeners: true,
            closesIneligibleTabs: true,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        SiteAdded() => (
            persists: true,
            savesWebspaces: true,
            prunesReferences: false,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        // Its hosted tabs closed before its container went (LIR-023).
        SiteRemoved() => (
            persists: true,
            savesWebspaces: true,
            prunesReferences: true,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: true,
            sweepsOrphans: true,
          ),
        SitesMoved() => (
            persists: true,
            savesWebspaces: true,
            prunesReferences: false,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        SitesReplaced() => (
            persists: true,
            savesWebspaces: true,
            prunesReferences: true,
            followsOpeners: true,
            closesIneligibleTabs: true,
            reschedulesBackground: true,
            sweepsOrphans: true,
          ),
        // Archive rows never enter app-tier storage, so an open or a close
        // writes nothing there (ARCH-001); what it changes at runtime is the
        // Tor refcount and the routes, which every change reconciles.
        ArchiveOpened() || ArchiveClosed() => (
            persists: false,
            savesWebspaces: false,
            prunesReferences: false,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        SiteArchived() => (
            persists: true,
            savesWebspaces: true,
            prunesReferences: true,
            followsOpeners: false,
            closesIneligibleTabs: true,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
        SiteUnarchived() => (
            persists: true,
            savesWebspaces: true,
            prunesReferences: true,
            followsOpeners: false,
            closesIneligibleTabs: false,
            reschedulesBackground: false,
            sweepsOrphans: false,
          ),
      };
}

/// Fields of existing sites changed: a page, a tab, a name, a toggle.
final class SitesEdited extends SiteSetChange {
  const SitesEdited();
}

final class SiteSettingsSaved extends SiteSetChange {
  const SiteSettingsSaved();
}

final class SiteSettingsClosed extends SiteSetChange {
  const SiteSettingsClosed();
}

/// The persisted sites, loaded at startup.
final class SitesLoaded extends SiteSetChange {
  const SitesLoaded(this.sites);
  final List<WebViewModel> sites;
}

/// A new site, appended and put in the selected named webspace.
final class SiteAdded extends SiteSetChange {
  const SiteAdded(this.site);
  final WebViewModel site;
}

final class SiteRemoved extends SiteSetChange {
  const SiteRemoved(this.site);
  final WebViewModel site;
}

/// The "All" order: the site at [from] moved to [to].
final class SitesMoved extends SiteSetChange {
  const SitesMoved(this.from, this.to);
  final int from;
  final int to;
}

/// A settings import replaced every site and webspace.
final class SitesReplaced extends SiteSetChange {
  const SitesReplaced({
    required this.sites,
    required this.webspaces,
    required this.selectedWebspaceId,
  });
  final List<WebViewModel> sites;
  final List<Webspace> webspaces;
  final String? selectedWebspaceId;
}

/// An open archive's sites and collections, materialised at the end of the
/// lists, its sites back in the app-tier collections they came from.
final class ArchiveOpened extends SiteSetChange {
  const ArchiveOpened({
    required this.sites,
    required this.webspaces,
    required this.appTierMembership,
  });
  final List<WebViewModel> sites;
  final List<Webspace> webspaces;
  final Map<String, List<String>> appTierMembership;
}

/// A sealed archive's rows leave the lists.
final class ArchiveClosed extends SiteSetChange {
  const ArchiveClosed({required this.siteIds, required this.webspaceIds});
  final Set<String> siteIds;
  final Set<String> webspaceIds;
}

/// An app-tier site moved into the open archive [into]; its row stays
/// where it is.
final class SiteArchived extends SiteSetChange {
  const SiteArchived(this.site, {required this.into});
  final WebViewModel site;
  final ArchiveHandle into;
}

/// An archived site moved back to the app tier.
final class SiteUnarchived extends SiteSetChange {
  const SiteUnarchived(this.site);
  final WebViewModel site;
}
