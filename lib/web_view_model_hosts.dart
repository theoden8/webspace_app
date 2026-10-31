import 'package:webspace/services/popup_webview.dart' show PopupKind;
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';

/// The site each of a site's tabs runs as (LIR-018), and what follows from
/// it: where the active tab is anchored (LIR-034) and where its back stack is
/// kept (LIR-022).
extension WebViewModelHosts on WebViewModel {
  /// The site [tab] runs as when that is not this one, or null.
  WebViewModel? hostOf(SiteTab tab) {
    final id = tab.hostSiteId;
    return id == null ? null : WebViewModel.siteLookup?.call(id);
  }

  /// The site this slot runs as (LIR-018): the host of the active tab, or
  /// this site. The slot itself — the webview, controller, loading state and
  /// the tab records — stays this site's.
  WebViewModel get runningIdentity => hostOf(activeTab) ?? this;

  /// The site each tab runs as, the model's `host[s]`.
  Map<TabId, WebViewModel> get tabHosts =>
      TabHosts({for (final t in tabs) t.id: hostOf(t) ?? this}, site: this);

  bool get runsHostedTab => activeTab.hostSiteId != null;

  /// The active tab names a host that is not there. The tab must close rather
  /// than load its host's URL as this site (LIR-023).
  bool get activeHostMissing => runsHostedTab && hostOf(activeTab) == null;

  /// Whether [tab] runs outside the domain of the site it runs as (LIR-034):
  /// a tab a link opened while its opener's routing was off, which runs as the
  /// opener inside the link's domain. Its container and posture are the site
  /// it runs as; the domain it navigates in is its [SiteTab.homeUrl]'s.
  bool isForeignTab(SiteTab tab) {
    final home = tab.homeUrl;
    if (home == null) return false;
    final identity = hostOf(tab) ?? this;
    return getNormalizedDomain(home) != getNormalizedDomain(identity.initUrl);
  }

  bool get runsForeignTab => isForeignTab(activeTab);

  /// Whether [tab] is a sign-in tab (NESTED-016): one a sign-in of the site it
  /// runs as opened at an identity provider's authorization request.
  bool isSignInTab(SiteTab tab) {
    final home = tab.homeUrl;
    return home != null && isForeignTab(tab) && PopupKind.isSignInRequest(home);
  }

  bool get runsSignInTab => isSignInTab(activeTab);

  /// Where the active tab's domain is anchored, and where Home (NAV-004) takes
  /// it: a foreign tab's home, else the home page of the site it runs as.
  String get navigationHomeUrl =>
      runsForeignTab ? activeTab.homeUrl! : runningIdentity.initUrl;

  /// The claims the active tab navigates by. A foreign tab borrows none from
  /// the site it runs as: only the link's own domain stays in place.
  bool navigationMatchesClaim(String url) =>
      !runsForeignTab && runningIdentity.matchesSiteClaim(url);

  /// Storage key for the active tab's `controller.saveState()` bytes. State is
  /// per tab, not per site: switching tabs captures under the outgoing tab's
  /// key and restores from the incoming one's (TAB-003). Keyed by the site the
  /// tab runs as (LIR-022), so wiping that site drops them.
  String get activeStateKey => stateKeyForTab(activeTabId);

  String stateKeyForTab(TabId tabId) {
    final tab = tabs.where((t) => t.id == tabId).firstOrNull;
    return webViewStateKey(tab?.hostSiteId ?? siteId, tabId: tabId);
  }

  /// Whether the active tab's back stack may be written (LIR-022): its record
  /// persists with this site's tab list, and the site it runs as keeps state.
  bool get activeTabPersistsNavState => tabPersistsNavState(activeTab);

  /// Whether [tab]'s back stack may be written: as
  /// [activeTabPersistsNavState], for any tab of this site.
  bool tabPersistsNavState(SiteTab tab) {
    if (!persistsNavState) return false;
    if (tab.hostSiteId == null) return true;
    final host = hostOf(tab);
    return host != null && host.persistsNavState;
  }
}
