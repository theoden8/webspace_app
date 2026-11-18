part of 'webspace_page.dart';

/// The page's answers to a link a site's own webview offers: the long-press
/// sheet (TAB-006) and a click that asks for a new tab (TAB-029).
extension _PageLinks on _WebSpacePageState {
  /// Where "Open in new tab" puts [url] from [model]'s tab on screen: a tab
  /// of the site's own when the link is in its domain, one running as another
  /// of the user's sites that can take it (LIR-032), or nowhere ([enabled]
  /// false). Null for a site without tabs.
  _NewTab? _newTabFor(WebViewModel model, {required String url}) {
    if (!_tabs.enabledFor(model)) return null;
    final identity = model.runningIdentity;
    final inDomain =
        getNormalizedDomain(url) == getNormalizedDomain(model.navigationHomeUrl);
    final route = inDomain
        ? null
        : _links.tabRouteFor(model,
            source: identity, url: url, hadGesture: true);
    return (inDomain: inDomain, route: route, identity: identity);
  }

  void _openNewTab(WebViewModel model,
      {required String url, required Uri uri, required _NewTab to}) {
    final (:route, :identity, inDomain: _) = to;
    if (route is DispatchShowPicker) {
      unawaited(_links.showOutboundPicker(model,
          source: identity, action: route, url: uri, parked: true));
    } else if (to.inDomain) {
      // A sibling of the tab on screen: same container, and when that tab
      // follows an opener's switch (LIR-034), so does it.
      final active = model.activeTab;
      unawaited(_tabs.openLinkInNewTab(model, url: url,
          hostSiteId: active.hostSiteId,
          openerSiteId: active.openerSiteId,
          homeUrl: active.homeUrl));
    } else {
      unawaited(_tabs.openLinkInNewTab(model, url: url,
          hostSiteId: _tabHostOf(to)?.siteId,
          openerSiteId: identity.siteId,
          homeUrl: url));
    }
  }

  WebViewModel? _tabHostOf(_NewTab to) => switch (to.route) {
        DispatchOpenInTab(:final siteId) => _sites.byId(siteId),
        _ => null,
      };

  /// A long press that landed on a link. In-domain links can become a tab of
  /// this site; anything else keeps today's behaviour, and the sheet says why
  /// rather than silently offering nothing. A site without tabs gets the sheet
  /// without its New tab row.
  Future<void> _showLinkLongPressMenu(WebViewModel model,
      {required String url}) async {
    if (_kioskLocked) return;
    if (!identical(model, _sites.shown)) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final newTab = _newTabFor(model, url: url);
    final tabHost = newTab == null ? null : _tabHostOf(newTab);
    final choice = await showLinkMenu(
      context,
      url: url,
      newTab: newTab == null
          ? null
          : (
              enabled: newTab.enabled,
              note: (loc) => newTab.inDomain
                  ? null
                  : tabHost != null
                      ? loc.tabsRunsAs(tabHost.getDisplayName())
                      : newTab.route == null
                          ? loc.tabsLinkOutsideSite(uri.host)
                          : null,
            ),
    );
    switch (choice) {
      case null:
        return;
      case LinkMenuChoice.newTab:
        if (newTab != null) _openNewTab(model, url: url, uri: uri, to: newTab);
      case LinkMenuChoice.open:
        unawaited(_links.openLinkAsTapped(model, url: url));
      case LinkMenuChoice.copy:
        await Clipboard.setData(ClipboardData(text: url));
      case LinkMenuChoice.share:
        unawaited(SharePlus.instance.share(ShareParams(uri: uri)));
    }
  }

  /// A link clicked to open in a new tab (TAB-029): the menu's "Open in new
  /// tab" where it is enabled, else the link opened as a tap, which is what
  /// the click would have done with no modifier.
  Future<void> _openLinkInNewTab(WebViewModel model,
      {required String url}) async {
    if (_kioskLocked) return;
    if (!identical(model, _sites.shown)) return;
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    final newTab = _newTabFor(model, url: url);
    if (newTab != null && newTab.enabled) {
      _openNewTab(model, url: url, uri: uri, to: newTab);
    } else {
      await _links.openLinkAsTapped(model, url: url);
    }
  }
}

/// Where "Open in new tab" puts a link: a tab of the site's own when it is
/// [inDomain], else wherever [route] sends it, nowhere when that is null.
typedef _NewTab = ({
  bool inDomain,
  DispatchAction? route,
  WebViewModel identity,
});

extension on _NewTab {
  bool get enabled => inDomain || route != null;
}
