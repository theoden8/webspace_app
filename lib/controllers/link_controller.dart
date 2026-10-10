import 'dart:async';

import 'package:webspace/controllers/page_host.dart';
import 'package:webspace/controllers/site_route.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/tabs_controller.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/html_import_storage.dart';
import 'package:webspace/services/link_intent_dispatch_engine.dart';
import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart'
    show NavigationDecision, NavigationDecisionEngine, NavigationStep;
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/page_title.dart';
import 'package:webspace/services/reentry_guard.dart';
import 'package:webspace/services/share_intent_service.dart';
import 'package:webspace/services/site_settings_qr_codec.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/web_search_engine.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/widgets/dispatch_picker_sheet.dart'
    show
        DispatchChoice,
        DispatchChoiceBind,
        DispatchChoiceCreate,
        DispatchChoiceFallback,
        DispatchChoiceOpen;
import 'package:webspace/widgets/external_url_prompt.dart'
    show launchUrlInSystemBrowser, showExternalLinkBlocked;
import 'package:webspace/widgets/url_bar.dart' show UrlBarSearchSite;
import 'package:webspace/widgets/web_search_sheet.dart' show WebSearchRequest;
import 'package:webspace/services/webview_controller.dart';

/// What the web search sheet is asked (LIR-029).
typedef WebSearchAsk = ({
  /// The site on screen: what "this site" means, and its own search.
  SearchSite identity,

  /// The user's sites a search from here may use.
  List<SearchSite> candidates,
  List<String> declared,
  String? declaredDefault,
  String? appDefault,

  /// False inside an archive (S15).
  bool canAddSites,
  String initialQuery,

  /// Container colours by siteId, empty on the legacy engine (TAB-018).
  Map<String, int> containerColors,
});

/// What a site picker is asked: LIR-010's for an inbound link, LIR-016's
/// (with [outboundSourceName]) for one a site opened.
typedef SitePick = ({
  Uri url,
  List<WebViewModel> winners,
  List<WebViewModel> otherSites,
  bool canBind,
  bool canCreate,
  bool claimDomains,
  String? outboundSourceName,
});

/// The questions the link flows put to the user.
abstract interface class LinkPrompts {
  Future<WebSearchRequest?> webSearch(WebSearchAsk ask);

  Future<DispatchChoice?> pickSite(SitePick pick);

  /// An HTML file shared in becomes a site only once reviewed (LIR-012).
  Future<bool> reviewSharedHtml({required String title, required String url});
}

/// What the link flows ask of the page.
abstract interface class LinkHost implements PageHost {
  bool get kioskLocked;

  Future<void> activate(int index);

  Future<void> saveCurrentIndex();

  /// Drops [siteId]'s cached HTML snapshot while online.
  void evictCache(String siteId);

  /// WEBSPACE-012: switches to "All" when the selected webspace hides
  /// [model].
  Future<void> revealSite(WebViewModel model, {required int index});

  /// Adds [model] and, with [activate], puts it on screen.
  Future<void> registerSite(WebViewModel model, {bool activate = true});

  /// A QR site-settings link shared in (`webspace://qr/`), reviewed by the
  /// add-site flow.
  Future<void> addSiteFromQr(Map<String, dynamic> settings);

  WebViewController? controllerOf(WebViewModel model);

  /// The page's one way to open a nested screen for a site (NESTED-010).
  Future<void> launchNestedFor(WebViewModel model, {required String url,
     bool opensFromTab = true});

  /// LIR-011 / LIR-015 through [NestedOpenEngine], over [source] when routed.
  Future<void> openNested(DispatchOpenNested action, {WebViewModel? source});

  Future<void> unloadSite(int index, {required UnloadReason reason});

  Future<void> wipeContainer(String siteId);

  ArchiveHandle? archiveOf(WebViewModel model);
}

/// Where links go: shares and deep links coming in (LIR-009 to LIR-012), a
/// site's links going out to the user's other sites (LIR-014 to LIR-017) or
/// into its tabs (LIR-032), web search (LIR-029 to LIR-033), and an address
/// typed or a link opened from the long-press menu.
class LinkController {
  LinkController(
    this._sites, {
    required LinkHost host,
    required LinkPrompts prompts,
    required TabsController tabs,
  })  : _host = host,
        _prompts = prompts,
        _tabs = tabs;

  final SiteRuntime _sites;
  final LinkHost _host;
  final LinkPrompts _prompts;
  final TabsController _tabs;

  final _shareIntentGuard = ReentryGuard();

  /// Takes the share or deep link the OS handed the app, at a cold start and
  /// on every resume.
  Future<void> handleShareIntent() async {
    if (_shareIntentGuard.busy) {
      LogTag.linkIntent.debug('poll skipped: re-entry guarded');
      return;
    }
    await _shareIntentGuard.run(() async {
      try {
        LogTag.linkIntent.debug('poll: consumeLaunchHtml');
        // HTML file payload first — the native side clears it after read,
        // so a tag mismatch (e.g. an HTML file that *also* has EXTRA_TEXT)
        // won't double-fire.
        final html = await ShareIntentService.consumeLaunchHtml();
        if (!_host.mounted) return;
        if (html != null) {
          if (!AppPref.linkHandlingEnabled.value) {
            LogTag.linkIntent.debug(
                'HTML share dropped (link handling disabled)');
            return;
          }
          LogTag.linkIntent.debug(
              'HTML share received (${html.content.length} bytes, title=${html.title})',
              sensitive: true);
          await dispatchInbound(InboundHtml(
            content: html.content,
            suggestedTitle: html.title,
            sourceUri: html.sourceUri,
          ));
          return;
        }
        LogTag.linkIntent.debug('poll: consumeLaunchUrl');
        final raw = await ShareIntentService.consumeLaunchUrl();
        if (!_host.mounted) return;
        if (raw == null || raw.isEmpty) {
          LogTag.linkIntent.debug('poll: no pending URL');
          return;
        }
        LogTag.linkIntent.debug('received: $raw', sensitive: true);
        if (!AppPref.linkHandlingEnabled.value) {
          LogTag.linkIntent.debug(
              'Share dropped (link handling disabled): $raw', sensitive: true);
          return;
        }
        if (raw.startsWith('webspace://qr/')) {
          final decoded = SiteSettingsQrCodec.decode(raw);
          if (decoded != null) {
            await _host.addSiteFromQr(decoded);
          } else {
            LogTag.linkIntent.warning(
                'QR payload failed to decode: $raw', sensitive: true);
          }
          return;
        }
        final parsed = Uri.tryParse(raw);
        if (parsed == null) {
          LogTag.linkIntent.warning('unparseable URL: $raw', sensitive: true);
          _host.toast((loc) => loc.homeUnsupportedUrl);
          return;
        }
        await dispatchInbound(InboundUrl(parsed));
      } catch (e, st) {
        LogTag.linkIntent.error(
            'share intent handler threw: $e\n$st', sensitive: true);
      }
    });
  }

  /// Engine-driven dispatch entry point: hands [payload] to
  /// [LinkIntentDispatchEngine] and executes the returned action. The
  /// engine owns the routing decisions; this method only performs IO and
  /// UI. See `lib/services/link_intent_dispatch_engine.dart`.
  Future<void> dispatchInbound(InboundPayload payload) async {
    final adapters = _sites.models
        .map((m) => SiteRoute(m))
        .toList(growable: false);
    final action = LinkIntentDispatchEngine.dispatch(
      payload: payload,
      sites: adapters,
    );
    final inboundUri = payload is InboundUrl ? payload.url : null;
    LogTag.linkIntent.debug(
        'dispatch ${inboundUri ?? '(html payload)'} -> ${_describeDispatchAction(action)}',
        sensitive: true);
    await _executeDispatchAction(action, inboundUri: inboundUri);
  }

  final _webSearchGuard = ReentryGuard();

  /// [m] as web search sees it (LIR-028).
  SearchSite _searchSiteOf(WebViewModel m) => SearchSite(
        siteId: m.siteId,
        name: m.getDisplayName(),
        initUrl: m.initUrl,
        capability: m.searchCapability,
      );

  /// Web search (LIR-029) from the site on screen: the sheet asks for a query
  /// and one of the user's search sites, and the results land by
  /// [WebSearchEngine.land].
  Future<void> webSearch({String initialQuery = ''}) async {
    if (_host.kioskLocked || _webSearchGuard.busy) return;
    final index = _sites.current;
    if (index == null || index < 0 || index >= _sites.models.length) return;
    await _webSearchGuard.run(() async {
      final owner = _sites.models[index];
      final identity = owner.runningIdentity;
      final appDefault = AppPref.webSearchDefaultSite.value;
      final candidates = [
        for (final m in {...outboundCandidates(owner), identity})
          _searchSiteOf(m),
      ];
      final request = await _prompts.webSearch((
        identity: _searchSiteOf(identity),
        candidates: candidates,
        declared: owner.searchSites,
        declaredDefault: owner.searchDefault,
        appDefault: appDefault.isEmpty ? null : appDefault,
        canAddSites: !owner.isArchiveTier,
        initialQuery: initialQuery,
        containerColors: {
          if (_sites.useContainers)
            for (final m in {...outboundCandidates(owner), identity})
              m.siteId: m.drawnContainerColor,
        },
      ));
      if (!_host.mounted || request == null) return;
      if (!_sites.models.contains(owner)) return;
      var option = request.option;
      final add = request.add;
      if (option == null && add != null && !owner.isArchiveTier) {
        // S10: the engine becomes one of the user's sites, then searches.
        final created = WebViewModel(
          initUrl: add.home,
          name: add.name,
          stateSetterF: _host.rebuild,
        );
        await _host.registerSite(created, activate: false);
        if (!_host.mounted) return;
        option = SearchOption(
          _searchSiteOf(created),
          scoped: request.scope == SearchScope.thisSite,
        );
      }
      if (option == null) return;
      final url = WebSearchEngine.urlFor(
        option,
        query: request.query,
        scopeHost: getNormalizedDomain(owner.navigationHomeUrl),
      );
      if (url == null) {
        _host.toast((loc) => loc.homeUnsupportedUrl);
        return;
      }
      await _runSearch(owner, searchSiteId: option.site.siteId, url: url);
    });
  }

  /// What the URL bar on [owner]'s slot searches with (LIR-033).
  ({List<UrlBarSearchSite> sites, String? defaultId}) urlBarSearchFor(
      WebViewModel owner) {
    final identity = owner.runningIdentity;
    final appDefault = AppPref.webSearchDefaultSite.value;
    final bar = WebSearchEngine.barOptions(
      identity: _searchSiteOf(identity),
      candidates: [
        for (final m in {...outboundCandidates(owner), identity})
          _searchSiteOf(m),
      ],
      declared: owner.searchSites,
      declaredDefault: owner.searchDefault,
      appDefault: appDefault.isEmpty ? null : appDefault,
    );
    return (
      sites: [
        for (final o in bar.options)
          UrlBarSearchSite(o.site.siteId, name: o.site.name),
      ],
      defaultId: bar.options.isEmpty
          ? null
          : bar.options[bar.preselected].site.siteId,
    );
  }

  /// A search typed in the URL bar (LIR-033): it runs as one from the sheet
  /// would, with the search site the bar names. With none, the sheet opens
  /// on the query, where a known engine can be added.
  Future<void> searchFromUrlBar(
    WebViewModel owner, {
    required String query,
    required String? siteId,
  }) async {
    if (_host.kioskLocked || _webSearchGuard.busy) return;
    if (!_sites.models.contains(owner)) return;
    final identity = owner.runningIdentity;
    final site = siteId == null ? null : _sites.byId(siteId);
    final reachable = site != null &&
        (identical(site, identity) ||
            outboundCandidates(owner).contains(site));
    if (!reachable) {
      await webSearch(initialQuery: query);
      return;
    }
    final url = WebSearchEngine.urlFor(
        SearchOption(_searchSiteOf(site), scoped: false), query: query);
    if (url == null) {
      _host.toast((loc) => loc.homeUnsupportedUrl);
      return;
    }
    await _webSearchGuard.run(() async {
      await _runSearch(owner, searchSiteId: site.siteId, url: url);
    });
  }

  /// Run a search by [searchSiteId] from [owner]'s slot, landing where
  /// [WebSearchEngine.land] says.
  Future<void> _runSearch(
    WebViewModel owner, {
    required String searchSiteId,
    required Uri url,
  }) async {
    final searchSite = _sites.byId(searchSiteId);
    final index = _sites.models.indexOf(owner);
    if (searchSite == null || index < 0) return;
    final identity = owner.runningIdentity;
    final landing = WebSearchEngine.land(
      (search: searchSiteId, owner: owner.siteId, identity: identity.siteId),
      tabsEnabled: owner.effectiveTabsEnabled,
      canHost: _tabs.mayHost(searchSite, owner: owner),
      urlInSearchSiteDomain:
          WebSearchEngine.inDomainOf(url, initUrl: searchSite.initUrl),
    );
    LogTag.webSearch.debug(
        'Search by ${searchSite.siteId} from ${owner.siteId}: ${landing.name}',
        sensitive: true);
    switch (landing) {
      case SearchLanding.inPlace:
        final controller = _host.controllerOf(owner);
        if (controller == null) return;
        await controller.loadUrl(url.toString(), language: identity.language);
        if (!_host.mounted) return;
        owner.currentUrl = url.toString();
        await _host.commitSites(const SitesEdited());
      case SearchLanding.childTab:
      case SearchLanding.hostedChildTab:
        await _tabs.openChildTab(owner,
            url: url.toString(), hostSiteId: searchSiteId);
      case SearchLanding.inSearchSite:
        await _executeDispatchAction(
          LinkIntentDispatchEngine.openInChosen(
            inbound: url,
            site: SiteRoute(searchSite),
            origin: InboundOrigin.search,
            tabsEnabled: searchSite.effectiveTabsEnabled,
          ),
          inboundUri: url,
        );
    }
  }

  String _describeDispatchAction(DispatchAction action) {
    switch (action) {
      case DispatchUnsupported(:final reason):
        return 'Unsupported($reason)';
      case DispatchOpenInMain(:final siteId, :final url, :final disposeBeforeLoad, :final wipeContainer, :final clearInMemoryCookies, :final newTab):
        final flags = [
          if (disposeBeforeLoad) 'dispose',
          if (wipeContainer) 'wipeContainer',
          if (clearInMemoryCookies) 'clearCookies',
          if (newTab) 'newTab',
        ].join(',');
        return 'OpenInMain(siteId=$siteId, url=$url${flags.isEmpty ? '' : ', $flags'})';
      case DispatchOpenNested(:final siteId, :final url, :final sourceIsParent):
        return 'OpenNested(siteId=$siteId, url=$url'
            '${sourceIsParent ? ', overSource' : ''})';
      case DispatchNestedFallback():
        return 'NestedFallback';
      case DispatchOpenInTab(:final siteId, :final url):
        return 'OpenInTab(siteId=$siteId, url=$url)';
      case DispatchCreateSite(:final home, :final fullUrl):
        return 'CreateSite(home=$home, fullUrl=$fullUrl)';
      case DispatchCreateSiteFromHtml(:final suggestedTitle):
        return 'CreateSiteFromHtml(title=$suggestedTitle)';
      case DispatchBindAndOpen(:final chosenSiteId, :final claimAdditions):
        return 'BindAndOpen(siteId=$chosenSiteId, +${claimAdditions.length} claims)';
      case DispatchShowPicker(:final winnerSiteIds, :final offerBind, :final offerCreate, :final source, :final asTab):
        return 'ShowPicker(winners=${winnerSiteIds.length}, '
            'bind=$offerBind, create=$offerCreate'
            '${source != null ? ', outbound' : ''}${asTab ? ', asTab' : ''})';
    }
  }

  Future<void> _executeDispatchAction(
    DispatchAction action, {
    required Uri? inboundUri,
  }) async {
    switch (action) {
      case DispatchUnsupported(:final reason):
        _host.toast((loc) => loc.homeUnsupportedShare(reason));
      case DispatchOpenInMain():
        await _executeOpenInMain(action);
      case DispatchOpenNested():
        await _host.openNested(action);
      case DispatchCreateSite():
        await _executeCreateSite(action);
      case DispatchCreateSiteFromHtml():
        await _executeCreateSiteFromHtml(action);
      case DispatchBindAndOpen():
        await _executeBindAndOpen(action);
      case DispatchShowPicker():
        if (inboundUri == null) return;
        await _showDispatchPicker(action, inbound: inboundUri);
      case DispatchNestedFallback():
      case DispatchOpenInTab():
        // Outbound only: `_executeOutboundDispatch` and `executeTabRoute`
        // run these with the site the link came from.
        LogTag.linkIntent.warning('outbound-only action on the inbound path: '
            '${_describeDispatchAction(action)}');
    }
  }

  /// The sites a link from [source] may route to (LIR-014): its own side of
  /// the archive boundary, which for an archive-tier source is the archive
  /// it belongs to.
  List<WebViewModel> outboundCandidates(WebViewModel source) =>
      OutboundBoundary.candidatesOf(
        source,
        sites: _sites.models,
        isArchiveTier: (m) => m.isArchiveTier,
        archiveOf: _host.archiveOf,
      );

  /// LIR-017: drop every outbound preference whose target is no longer a
  /// candidate of its source. True when any site's list changed; the caller
  /// persists.
  bool pruneOutboundPreferences() =>
      OutboundPreferenceGc.pruneAcrossBoundary<WebViewModel>(
        _sites.models,
        siteIdOf: (m) => m.siteId,
        isArchiveTier: (m) => m.isArchiveTier,
        archiveOf: _host.archiveOf,
        prefsOf: (m) => m.outboundPreferences,
        setPrefs: (m, {required prefs}) => m.outboundPreferences = prefs,
      );

  /// LIR-031: a site's search sites and default may name only sites a search
  /// from it could use (its side of the archive boundary), and the app default
  /// only a site outside every archive (ARCH-001). Same sites as LIR-017.
  bool pruneSearchReferences() {
    var changed = false;
    for (final m in _sites.models) {
      final ids = {for (final c in outboundCandidates(m)) c.siteId};
      if (m.pruneSearchReferences(ids.contains)) changed = true;
    }
    _pruneSearchDefaultPref();
    return changed;
  }

  void _pruneSearchDefaultPref() {
    final id = AppPref.webSearchDefaultSite.value;
    if (id.isEmpty) return;
    final site = _sites.byId(id);
    if (site == null || site.isArchiveTier) {
      unawaited(AppPref.webSearchDefaultSite.set(''));
    }
  }

  /// [owner]'s hook into its own webview's navigation (LIR-014).
  /// [owner]'s webview is about to nest [url], hand it to the system
  /// browser or block it. True when routing took the link over, so the
  /// webview must not also launch it. The link is the running identity's
  /// (LIR-018): its routing, preferences and posture; the slot is [owner]'s.
  bool routeOutbound(
    WebViewModel owner, {
    required String url,
    required NavigationDecision decision,
    required bool hadGesture,
  }) {
    if (!_host.mounted) return false;
    final source = owner.runningIdentity;
    if (decision == NavigationDecision.blockOutbound) {
      if (hadGesture) showExternalLinkBlocked(url);
      return true;
    }
    if (decision == NavigationDecision.blockOpenNested) {
      final tab =
          tabRouteFor(owner, source: source, url: url, hadGesture: hadGesture);
      if (tab != null) {
        unawaited(executeTabRoute(owner,
            source: source,
            parentTabId: owner.activeTabId,
            action: tab,
            url: Uri.parse(url)));
        return true;
      }
    }
    final action = LinkIntentDispatchEngine.routeOutbound(
      url: url,
      decision: decision,
      routeOutboundLinks: source.effectiveRouteOutboundLinks,
      kioskLocked: _host.kioskLocked,
      hadGesture: hadGesture,
      containersActive: _sites.useContainers,
      source: SiteRoute(source),
      sourcePrefs: source.outboundPreferences,
      candidates: () => [
        for (final m in outboundCandidates(source)) SiteRoute(m),
      ],
    );
    if (action == null) return false;
    LogTag.linkIntent.debug(
        'outbound $url from ${source.siteId} -> ${_describeDispatchAction(action)}',
        sensitive: true);
    unawaited(_executeOutboundDispatch(owner,
        source: source, action: action, url: Uri.parse(url)));
    return true;
  }

  /// LIR-032: a link from [source] (on screen in [owner]'s slot, or in a
  /// nested screen over it) into one of the user's sites opens as a tab run
  /// as that site, not a nested screen. Null when no site of the user's can
  /// run it in [owner]'s tree.
  DispatchAction? tabRouteFor(
    WebViewModel owner, {
    required WebViewModel source,
    required String url,
    required bool hadGesture,
  }) {
    final uri = Uri.tryParse(url);
    if (uri == null || !_sites.models.contains(owner)) return null;
    final action = LinkIntentDispatchEngine.routeToTab(
      url: uri,
      urlNavigationDomain: getNormalizedDomain(url),
      tabsEnabled: owner.effectiveTabsEnabled,
      routeOutboundLinks: source.effectiveRouteOutboundLinks,
      containersActive: _sites.useContainers,
      kioskLocked: _host.kioskLocked,
      hadGesture: hadGesture,
      source: SiteRoute(source),
      sourcePrefs: source.outboundPreferences,
      hosts: () => tabHostsIn(owner, source: source),
    );
    // LIR-034: routing off runs the tab as its opener, which must be able to
    // run in this tree: the owner, or a site that may host here.
    if (action is DispatchOpenInTab &&
        action.siteId == source.siteId &&
        !identical(source, owner) &&
        !_tabs.mayHost(source, owner: owner)) {
      return null;
    }
    return action;
  }

  /// The sites that can run a link of [source]'s as a tab in [owner]'s tree.
  List<SiteRoute> tabHostsIn(WebViewModel owner,
          {required WebViewModel source}) =>
      [
        for (final m in outboundCandidates(source))
          if (identical(m, owner) || _tabs.mayHost(m, owner: owner))
            SiteRoute(m),
      ];

  /// Run [tabRouteFor]'s action: a child of [parentTabId] in [owner]'s tree,
  /// or the picker when several sites can run the link.
  Future<void> executeTabRoute(
    WebViewModel owner, {
    required WebViewModel source,
    required String? parentTabId,
    required DispatchAction action,
    required Uri url,
  }) async {
    LogTag.linkIntent.debug(
        'link $url from ${source.siteId} as a tab of ${owner.siteId} -> '
        '${_describeDispatchAction(action)}', sensitive: true);
    switch (action) {
      case DispatchOpenInTab(:final siteId):
        await _tabs.openChildTab(owner, url: url.toString(),
            hostSiteId: siteId,
            parentTabId: parentTabId,
            openerSiteId: source.siteId,
            homeUrl: url.toString());
      case DispatchShowPicker():
        await showOutboundPicker(owner,
            source: source, action: action, url: url, parentTabId: parentTabId);
      default:
        LogTag.linkIntent.warning(
            'unexpected action on the tab path: ${_describeDispatchAction(action)}');
    }
  }

  /// [owner] is the slot the link came from; [source] is what it runs as.
  Future<void> _executeOutboundDispatch(
    WebViewModel owner, {
    required WebViewModel source,
    required DispatchAction action,
    required Uri url,
  }) async {
    switch (action) {
      case DispatchOpenNested():
        // The screen opens over the slot on screen, which is what comes back
        // when it closes, whatever that slot runs as.
        await _host.openNested(action, source: owner);
      case DispatchShowPicker():
        await showOutboundPicker(owner,
            source: source, action: action, url: url);
      case DispatchNestedFallback():
        await _host.launchNestedFor(source, url: url.toString());
      default:
        LogTag.linkIntent.warning('inbound-only action on the outbound path: '
            '${_describeDispatchAction(action)}');
    }
  }

  /// LIR-016: the picker for a link [source] opens that several sites claim.
  /// [owner] is the slot on screen; a pick opens a nested screen over it, or
  /// a tab in its tree when the picker is LIR-032's.
  Future<void> showOutboundPicker(
    WebViewModel owner, {
    required WebViewModel source,
    required DispatchShowPicker action,
    required Uri url,
    String? parentTabId,
    bool parked = false,
  }) async {
    final winners = [
      for (final m in outboundCandidates(source))
        if (action.winnerSiteIds.contains(m.siteId)) m,
    ];
    if (!_host.mounted) return;
    final choice = await _prompts.pickSite((
      url: url,
      winners: winners,
      otherSites: const [],
      canBind: false,
      canCreate: false,
      claimDomains: false,
      outboundSourceName: source.getDisplayName(),
    ));
    if (!_host.mounted || choice == null) return;
    switch (choice) {
      case DispatchChoiceOpen(:final site, :final remember):
        final pick = LinkIntentDispatchEngine.pickOutbound(
          url: url,
          site: SiteRoute(site),
          remember: remember,
          existing: source.outboundPreferences,
        );
        if (pick.preferences case final preferences?) {
          source.outboundPreferences = preferences;
          await _host.commitSites(const SitesEdited());
          if (!_host.mounted) return;
        }
        if (action.asTab && parked) {
          await _tabs.openLinkInNewTab(
              _sites.models.indexOf(owner), url: url.toString(),
              hostSiteId: site.siteId,
              openerSiteId: source.siteId,
              homeUrl: url.toString());
        } else if (action.asTab) {
          await _tabs.openChildTab(owner, url: url.toString(),
              hostSiteId: site.siteId,
              parentTabId: parentTabId,
              openerSiteId: source.siteId,
              homeUrl: url.toString());
        } else {
          await _host.openNested(pick.action, source: owner);
        }
      case DispatchChoiceFallback():
        await _executeOutboundDispatch(owner,
            source: source, action: const DispatchNestedFallback(), url: url);
      case DispatchChoiceBind():
      case DispatchChoiceCreate():
        return;
    }
  }

  /// Hosts the LIR-010 picker. Translates the user's choice into a
  /// follow-up engine call and executes the result.
  Future<void> _showDispatchPicker(
    DispatchShowPicker action, {
    required Uri inbound,
  }) async {
    final winners = _sites.models
        .where((m) => action.winnerSiteIds.contains(m.siteId))
        .toList(growable: false);
    final others = _sites.models
        .where((m) => !action.winnerSiteIds.contains(m.siteId))
        .toList(growable: false);
    if (!_host.mounted) return;
    final choice = await _prompts.pickSite((
      url: inbound,
      winners: winners,
      otherSites: others,
      canBind: action.offerBind,
      canCreate: action.offerCreate,
      claimDomains: AppPref.linkHandlingClaimDomains.value,
      outboundSourceName: null,
    ));
    if (!_host.mounted || choice == null) return;
    final DispatchAction followUp;
    switch (choice) {
      case DispatchChoiceOpen(:final site):
        followUp = LinkIntentDispatchEngine.openInChosen(
          inbound: inbound,
          site: SiteRoute(site),
        );
      case DispatchChoiceBind(:final site):
        followUp = LinkIntentDispatchEngine.sendToSite(
          inbound: inbound,
          site: SiteRoute(site),
          claimDomain: AppPref.linkHandlingClaimDomains.value,
        );
      case DispatchChoiceCreate():
        followUp =
            LinkIntentDispatchEngine.createNew(inbound: inbound);
      case DispatchChoiceFallback():
        return;
    }
    await _executeDispatchAction(followUp, inboundUri: inbound);
  }

  /// LIR-011: dispose first when alwaysOpenHome / incognito; wipe
  /// container + clear cookies when incognito. Then activate and load.
  Future<void> _executeOpenInMain(DispatchOpenInMain a) async {
    final index =
        _sites.models.indexWhere((m) => m.siteId == a.siteId);
    if (index < 0) {
      LogTag.linkIntent.warning(
          'OpenInMain bailed: site ${a.siteId} not found', sensitive: true);
      return;
    }
    final model = _sites.models[index];
    await _host.revealSite(model, index: index);
    if (!_host.mounted) return;
    if (model.runsHostedTab || model.runsForeignTab) {
      // An owner URL never loads into a slot running as another site, nor
      // into a tab anchored in another domain (LIR-034).
      await _tabs.runWhenIdle(() => _tabs.switchToOwnerRunTab(model));
      if (!_host.mounted) return;
    }
    if (a.disposeBeforeLoad) {
      _host.evictCache(model.siteId);
      // Re-resolve by identity: `_sites.loaded` is positional and the site
      // list may have shifted (a lower-indexed delete) across the await, so
      // the captured `index` could now name a different site.
      final idx = _sites.models.indexOf(model);
      if (_sites.loaded.contains(idx)) {
        await _host.unloadSite(idx, reason: UnloadReason.homeReset);
        if (!_host.mounted) return;
      } else {
        model.disposeWebView();
      }
      model.currentUrl = model.initUrl;
    }
    if (a.wipeContainer) {
      await _host.wipeContainer(model.siteId);
    }
    if (a.clearInMemoryCookies) {
      model.cookies = const [];
    }
    if (!_host.mounted) return;
    final activateIndex = _sites.models.indexOf(model);
    if (activateIndex < 0) return; // deleted during the awaits above
    // A search opens its own tab (LIR-030). Tabs can have been switched off
    // since the engine decided; the search then loads in place.
    if (a.newTab && _tabs.enabledAt(activateIndex)) {
      await _tabs.newTab(activateIndex, url: a.url);
      return;
    }
    if (activateIndex != _sites.current) {
      await _host.activate(activateIndex);
    }
    if (!_host.mounted) return;
    final controller = _host.controllerOf(model);
    if (controller == null) {
      LogTag.linkIntent.warning(
          'OpenInMain: controller not yet ready for "${model.name}" '
          '(siteId: ${model.siteId}); ${a.url} may queue until first frame',
          sensitive: true);
      return;
    }
    await controller.loadUrl(a.url, language: model.language);
    if (!_host.mounted) return;
    model.currentUrl = a.url;
    await _host.commitSites(const SitesEdited());
  }

  /// LIR-009 + LIR-010 option 3: create a brand-new site rooted at the
  /// stripped home URL with a synthesized `baseDomain` claim, then
  /// navigate the new webview to the full inbound URL on first activation.
  Future<void> _executeCreateSite(DispatchCreateSite a) async {
    final model = WebViewModel(
      initUrl: a.home,
      domainClaims: a.initialClaims.isEmpty ? null : a.initialClaims,
      stateSetterF: _host.rebuild,
    );
    final pageTitle = await getPageTitle(a.fullUrl);
    if (!_host.mounted) return;
    if (pageTitle != null && pageTitle.isNotEmpty) {
      model.name = pageTitle;
      model.pageTitle = pageTitle;
    }
    await _host.registerSite(model);
    if (!_host.mounted) return;
    final controller = _host.controllerOf(model);
    if (controller != null && a.fullUrl != a.home) {
      await controller.loadUrl(a.fullUrl, language: model.language);
      if (!_host.mounted) return;
      model.currentUrl = a.fullUrl;
      await _host.commitSites(const SitesEdited());
    }
  }

  /// LIR-012: an HTML file share short-circuits to "create new site"
  /// (only sensible action — opaque file content can't be claimed by an
  /// existing site). HTML lives in `HtmlImportStorage`, identical to the
  /// in-app file-import flow. On Android any app can deliver this share
  /// without the chooser, so the site is reviewed first and never put on
  /// screen unasked.
  Future<void> _executeCreateSiteFromHtml(
    DispatchCreateSiteFromHtml a,
  ) async {
    final fileSiteUrl =
        'file:///webspace_import_${DateTime.now().microsecondsSinceEpoch}.html';
    final title = a.suggestedTitle?.trim() ?? '';
    final accepted =
        await _prompts.reviewSharedHtml(title: title, url: fileSiteUrl);
    if (!accepted || !_host.mounted) return;
    final model = WebViewModel(
      initUrl: fileSiteUrl,
      stateSetterF: _host.rebuild,
    );
    if (title.isNotEmpty) {
      model.name = title;
      model.pageTitle = title;
    }
    await HtmlImportStorage.instance
        .saveHtml(model.siteId, html: a.html, url: fileSiteUrl);
    if (!_host.mounted) return;
    await _host.registerSite(model, activate: false);
  }

  /// Persist [a.claimAdditions] onto the chosen site (deduped against
  /// existing claims) and then execute the engine-computed [a.followUp].
  Future<void> _executeBindAndOpen(DispatchBindAndOpen a) async {
    final idx =
        _sites.models.indexWhere((m) => m.siteId == a.chosenSiteId);
    if (idx < 0) return;
    final site = _sites.models[idx];
    if (a.claimAdditions.isNotEmpty) {
      final existing = site.domainClaims ?? site.effectiveDomainClaims;
      site.domainClaims =
          LinkRoutingService.mergeClaims(existing, additions: a.claimAdditions);
      await _host.commitSites(const SitesEdited());
    }
    await _executeDispatchAction(a.followUp, inboundUri: null);
  }

  /// Open [url] from the long-press menu the way tapping the link would have:
  /// in place when it is this site's, otherwise nested or in the system
  /// browser (NESTED-010). A bare `loadUrl` would put a foreign page inside
  /// the site's container, because Android does not run
  /// `shouldOverrideUrlLoading` for a programmatic load.
  Future<void> openLinkAsTapped(int index, {required String url}) async {
    if (index < 0 || index >= _sites.models.length) return;
    final model = _sites.models[index];
    final active = index == _sites.current;
    // A hosted tab navigates by its host's rules (LIR-018), except that a
    // link back into the owner's domain returns to the owner.
    final identity = model.runningIdentity;
    // Choosing Open is a user gesture, so routing (LIR-014) sees it as a tap.
    final decision = identity.decideUserOpenedLink(url,
        isActive: active,
        homeUrl: model.navigationHomeUrl,
        matchesClaim: model.navigationMatchesClaim);
    if ((model.runsHostedTab || model.runsForeignTab) &&
        decision != NavigationDecision.allow &&
        getNormalizedDomain(url) == getNormalizedDomain(model.initUrl)) {
      await _tabs.returnToOwner(model, url: url);
      return;
    }
    switch (decision) {
      case NavigationDecision.allow:
        await _host.controllerOf(model)
            ?.loadUrl(url, language: identity.language);
      case NavigationDecision.blockOpenNested:
        if (routeOutbound(model,
            url: url,
            decision: NavigationDecision.blockOpenNested,
            hadGesture: true)) {
          return;
        }
        await _host.launchNestedFor(identity, url: url);
      case NavigationDecision.blockOpenExternal:
        if (routeOutbound(model,
            url: url,
            decision: NavigationDecision.blockOpenExternal,
            hadGesture: true)) {
          return;
        }
        await launchUrlInSystemBrowser(url);
      case NavigationDecision.blockOutbound:
        routeOutbound(model,
            url: url,
            decision: NavigationDecision.blockOutbound,
            hadGesture: true);
      case NavigationDecision.blockSilent:
      case NavigationDecision.blockSuppressed:
        break;
    }
  }

  /// An address typed in [model]'s URL bar goes where a tapped link to it
  /// would: the same decision and the same steps after it, so tab routing
  /// (LIR-032, LIR-034), outbound routing (LIR-014), the site's external link
  /// mode and the way back to the owner (S6) all apply to it.
  Future<void> openTypedAddress(WebViewModel model, {required String url}) async {
    // Decide on the tab the switch in flight lands on, not the one it leaves.
    await _tabs.settled();
    if (!_host.mounted || !_sites.models.contains(model)) return;
    final identity = model.runningIdentity;
    final decision = NavigationDecisionEngine.decideShouldOverrideUrlLoading(
      targetUrl: url,
      initUrl: model.navigationHomeUrl,
      hasGesture: true,
      isSiteActive: true,
      lastSameDomainGestureTime: null,
      now: DateTime.now(),
      externalLinkMode: identity.effectiveExternalLinkMode,
      matchesSiteClaim: model.navigationMatchesClaim,
    ).decision;
    final step = NavigationDecisionEngine.stepFor(
      decision,
      returnsToOwner: (model.runsHostedTab || model.runsForeignTab) &&
          model.effectiveTabsEnabled &&
          getNormalizedDomain(url) == getNormalizedDomain(model.initUrl),
    );
    switch (step) {
      case NavigationStep.drop:
        return;
      case NavigationStep.returnToOwner:
        await _tabs.returnToOwner(model, url: url);
      case NavigationStep.route:
        if (routeOutbound(model, url: url, decision: decision, hadGesture: true)) return;
        if (decision == NavigationDecision.blockOpenNested) {
          await _host.launchNestedFor(identity, url: url);
        } else if (decision == NavigationDecision.blockOpenExternal) {
          await launchUrlInSystemBrowser(url);
        }
      case NavigationStep.loadHere:
        await _tabs.runWhenIdle(() async {
          final controller = _host.controllerOf(model);
          if (controller == null) return;
          await controller.loadUrl(url, language: identity.language);
          if (!_host.mounted) return;
          model.currentUrl = url;
          await _host.commitSites(const SitesEdited());
        });
    }
  }
}
