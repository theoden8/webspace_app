/// Pure-Dart logic engine for dispatching inbound share/open intents to a
/// site (LIR-002, LIR-009, LIR-010, LIR-011, LIR-012). Mirrors the engine
/// pattern in `cookie_isolation.dart` / `site_activation_engine.dart`:
/// the engine returns a [DispatchAction] describing what should happen,
/// and `_WebSpacePageState` performs the IO/UI side-effects. No Flutter,
/// no platform channels, no setState — fully testable with fakes.
library;

import 'package:webspace/services/link_routing_service.dart';
import 'package:webspace/services/navigation_decision_engine.dart'
    show NavigationDecision;
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/web_view_model.dart' show getBaseDomain, getNormalizedDomain;

/// What the OS handed us. `webspace://open?url=...` URLs are unwrapped to
/// `InboundUrl` before dispatch; `text/html` shares (Android) and HTML
/// files dropped via the future iOS Share Extension arrive as
/// `InboundHtml`.
sealed class InboundPayload {
  const InboundPayload();
}

class InboundUrl extends InboundPayload {
  final Uri url;
  const InboundUrl(this.url);
}

class InboundHtml extends InboundPayload {
  /// Whole HTML document.
  final String content;

  /// Display name, derived from filename or `<title>`. Used as the new
  /// site's `name` and `pageTitle`.
  final String? suggestedTitle;

  /// Optional source URI (typically `file://` or `content://`) — purely
  /// informational; the engine never opens it.
  final String? sourceUri;

  const InboundHtml({
    required this.content,
    this.suggestedTitle,
    this.sourceUri,
  });
}

/// Subset of [WebViewModel] the engine needs. Adapter lives at the call
/// site so the engine has zero dependency on Flutter.
abstract class DispatchableSite implements RoutableSite {
  bool get incognito;
  bool get alwaysOpenHome;

  /// `getNormalizedDomain(initUrl)` — used for the in-domain main-vs-
  /// nested split. Pre-computed by the adapter so the engine never
  /// imports the alias table.
  String get navigationDomain;
}

sealed class DispatchAction {
  const DispatchAction();
}

/// Inbound URL is malformed, non-http(s), or has an empty host. The view
/// surfaces a snackbar and otherwise no-ops.
class DispatchUnsupported extends DispatchAction {
  final String reason;
  const DispatchUnsupported(this.reason);
}

/// Activate [siteId] and load [url] into its main webview.
///
/// `disposeBeforeLoad`/`wipeContainer`/`clearInMemoryCookies` are non-
/// negotiable: when the engine emits them, the executor MUST honour them
/// before activating. They are how the engine enforces the
/// always-open-home / incognito reset (LIR-011) so an inbound share
/// can't be loaded into an existing webview that's mid-session — a
/// defence against IP / session leakage across share boundaries.
class DispatchOpenInMain extends DispatchAction {
  final String siteId;
  final String url;
  final bool disposeBeforeLoad;
  final bool wipeContainer;
  final bool clearInMemoryCookies;
  const DispatchOpenInMain({
    required this.siteId,
    required this.url,
    required this.disposeBeforeLoad,
    required this.wipeContainer,
    required this.clearInMemoryCookies,
  });
}

/// Open [url] in a nested in-app webview carrying the chosen site's
/// privacy settings. Used for cross-domain shares (LIR-011) so a site's
/// main session is not clobbered, and for outbound routing (LIR-015).
class DispatchOpenNested extends DispatchAction {
  final String siteId;
  final String url;

  /// The screen opens over a site the user is browsing (outbound routing),
  /// so the executor leaves the webspace alone rather than switching to one
  /// that shows [siteId].
  final bool sourceIsParent;

  const DispatchOpenNested({
    required this.siteId,
    required this.url,
    this.sourceIsParent = false,
  });
}

/// What the navigation engine had decided for an outbound link before
/// routing looked at it.
enum OutboundFallback { nested, external }

/// Outbound routing named no destination for a `blockOpenNested` decision:
/// open the nested screen with the source's own posture, as without routing.
class DispatchNestedFallback extends DispatchAction {
  const DispatchNestedFallback();
}

/// Outbound routing named no destination for a `blockOpenExternal`
/// decision: hand [url] to the system browser, as without routing.
class DispatchOpenExternal extends DispatchAction {
  final String url;
  const DispatchOpenExternal(this.url);
}

/// Create a brand-new site rooted at [home] (the stripped path) with
/// [initialClaims], then navigate the new webview to [fullUrl] (which
/// may equal [home]) on first activation.
class DispatchCreateSite extends DispatchAction {
  final String home;
  final String fullUrl;
  final List<DomainClaim> initialClaims;
  const DispatchCreateSite({
    required this.home,
    required this.fullUrl,
    required this.initialClaims,
  });
}

/// Create a brand-new site whose `initialHtml` is [html]. There is no
/// remote URL — the file lives in `HtmlImportStorage`. Naming hints from
/// [InboundHtml.suggestedTitle].
class DispatchCreateSiteFromHtml extends DispatchAction {
  final String html;
  final String? suggestedTitle;
  const DispatchCreateSiteFromHtml({
    required this.html,
    this.suggestedTitle,
  });
}

/// Surface the LIR-010 picker. The view owns the UI, including the
/// secondary site picker for the bind option. Once the user picks, call
/// back into `LinkIntentDispatchEngine.openInChosen`,
/// `bindToSite`, or `createNew` to get the follow-up action.
class DispatchShowPicker extends DispatchAction {
  final List<String> winnerSiteIds;
  final bool offerBind;
  final bool offerCreate;

  /// Set for an outbound picker (LIR-016): the site whose link is being
  /// routed. It gets the remember checkbox and an "Open without routing" row.
  final String? source;

  /// What "Open without routing" does; set whenever [source] is.
  final OutboundFallback? fallback;

  const DispatchShowPicker({
    required this.winnerSiteIds,
    required this.offerBind,
    required this.offerCreate,
    this.source,
    this.fallback,
  });
}

/// Pre-append [claimAdditions] to the chosen site (deduped) and persist;
/// then run [followUp]. Distilled into one action so the executor never
/// computes "what comes after binding" on its own — that decision is
/// fully owned by the engine.
class DispatchBindAndOpen extends DispatchAction {
  final String chosenSiteId;
  final List<DomainClaim> claimAdditions;
  final DispatchAction followUp;
  const DispatchBindAndOpen({
    required this.chosenSiteId,
    required this.claimAdditions,
    required this.followUp,
  });
}

class LinkIntentDispatchEngine {
  LinkIntentDispatchEngine._();

  /// Initial dispatch on payload arrival. Returns the action the view
  /// should execute. For an HTML file payload there is no router stage —
  /// the only sensible operation is "create a new site for this file"
  /// (LIR-012); existing sites can't claim opaque file content.
  static DispatchAction dispatch({
    required InboundPayload payload,
    required List<DispatchableSite> sites,
  }) {
    if (payload is InboundHtml) {
      if (payload.content.isEmpty) {
        return const DispatchUnsupported('empty HTML payload');
      }
      return DispatchCreateSiteFromHtml(
        html: payload.content,
        suggestedTitle: payload.suggestedTitle,
      );
    }
    final url = (payload as InboundUrl).url;
    final target = _normalizeInbound(url);
    if (target == null) {
      return const DispatchUnsupported('non-http(s) target or empty host');
    }
    final match = LinkRoutingService.resolve(target, sites);
    if (match is RoutingSingle) {
      return _openInExisting(match.site as DispatchableSite, target);
    }
    return DispatchShowPicker(
      winnerSiteIds: match is RoutingAmbiguous
          ? match.sites
              .map((s) => s.siteId)
              .toList(growable: false)
          : const [],
      offerBind: sites.isNotEmpty,
      offerCreate: LinkRoutingService.strippedHomeUrl(target) != null,
    );
  }

  /// Whether routing takes a link [source]'s own webview is about to launch
  /// under [decision] (LIR-014). Null means it does not, and the webview's
  /// own launch runs: routing is off for the source, the experimental
  /// feature is off (DEVTOOLS-011), the kiosk shell is locked (KIOSK-002),
  /// the decision is
  /// not a nested or external launch, or [dispatchOutbound] names no
  /// destination. [candidates] is read only once the cheap gates pass.
  static DispatchAction? routeOutbound({
    required String url,
    required NavigationDecision decision,
    required bool routeOutboundLinks,
    required bool experimentEnabled,
    required bool kioskLocked,
    required bool hadGesture,
    required bool containersActive,
    required DispatchableSite source,
    required List<OutboundPreference> sourcePrefs,
    required List<DispatchableSite> Function() candidates,
  }) {
    if (!routeOutboundLinks || !experimentEnabled || kioskLocked) return null;
    final fallback = switch (decision) {
      NavigationDecision.blockOpenNested => OutboundFallback.nested,
      NavigationDecision.blockOpenExternal => OutboundFallback.external,
      _ => null,
    };
    if (fallback == null) return null;
    final target = Uri.tryParse(url);
    if (target == null) return null;
    final action = dispatchOutbound(
      targetUrl: target,
      source: source,
      sourcePrefs: sourcePrefs,
      candidates: candidates(),
      fallback: fallback,
      hadGesture: hadGesture,
      containersActive: containersActive,
    );
    return switch (action) {
      DispatchNestedFallback() || DispatchOpenExternal() => null,
      _ => action,
    };
  }

  /// A link the source site opens, which the navigation engine decided to
  /// nest or send to the system browser (LIR-014, LIR-015). The caller has
  /// already checked `routeOutboundLinks`. Routing needs a gesture and the
  /// container engine; without either, or when nothing but the source claims
  /// the link, the navigation engine's decision stands.
  static DispatchAction dispatchOutbound({
    required Uri targetUrl,
    required DispatchableSite source,
    required List<OutboundPreference> sourcePrefs,
    required List<DispatchableSite> candidates,
    required OutboundFallback fallback,
    required bool hadGesture,
    required bool containersActive,
  }) {
    final unrouted = unroutedOutbound(url: targetUrl, fallback: fallback);
    if (!hadGesture || !containersActive) return unrouted;
    final resolution = LinkRoutingService.resolveOutbound(
      targetUrl,
      source.siteId,
      sourcePrefs,
      candidates,
    );
    switch (resolution) {
      case OutboundByPreference(:final site):
      case OutboundByClaims(match: RoutingSingle(:final site)):
        return openOutbound(url: targetUrl, site: site);
      case OutboundByClaims(match: RoutingAmbiguous(:final sites)):
        return DispatchShowPicker(
          winnerSiteIds:
              sites.map((s) => s.siteId).toList(growable: false),
          offerBind: false,
          offerCreate: false,
          source: source.siteId,
          fallback: fallback,
        );
      case OutboundByClaims(match: RoutingNone()):
      case OutboundSelfMatch():
        return unrouted;
    }
  }

  /// What an outbound link does when routing names no destination, or the
  /// user picks "Open without routing": the navigation engine's own decision.
  static DispatchAction unroutedOutbound({
    required Uri url,
    required OutboundFallback fallback,
  }) =>
      switch (fallback) {
        OutboundFallback.nested => const DispatchNestedFallback(),
        OutboundFallback.external => DispatchOpenExternal(url.toString()),
      };

  /// A routed outbound link, or the user's pick from the outbound picker: a
  /// nested screen with [site]'s posture over the source, never a webspace
  /// switch and never the destination's main webview (LIR-015).
  static DispatchOpenNested openOutbound({
    required Uri url,
    required RoutableSite site,
  }) =>
      DispatchOpenNested(
        siteId: site.siteId,
        url: url.toString(),
        sourceIsParent: true,
      );

  /// The user picked [site] in the outbound picker (LIR-016): the routed
  /// open, and with [remember] the source's preference list grown by
  /// [preferencesToRemember]. `preferences` is null when the list does not
  /// change, so the caller persists only on a change.
  static ({List<OutboundPreference>? preferences, DispatchOpenNested action})
      pickOutbound({
    required Uri url,
    required RoutableSite site,
    required bool remember,
    required List<OutboundPreference> existing,
  }) {
    final additions = remember
        ? preferencesToRemember(
            url: url,
            targetSiteId: site.siteId,
            existing: existing,
          )
        : const <OutboundPreference>[];
    return (
      preferences: additions.isEmpty ? null : [...existing, ...additions],
      action: openOutbound(url: url, site: site),
    );
  }

  /// The preferences a remembered outbound pick adds to the source
  /// (LIR-016): one per claim of [url] the source does not hold yet, whatever
  /// that claim's current target.
  static List<OutboundPreference> preferencesToRemember({
    required Uri url,
    required String targetSiteId,
    required List<OutboundPreference> existing,
  }) {
    final held = {for (final p in existing) p.claim};
    return [
      for (final claim in LinkRoutingService.claimsToAdoptUrl(url))
        if (held.add(claim))
          OutboundPreference(claim: claim, targetSiteId: targetSiteId),
    ];
  }

  /// User picked an "Open in [site]" row from the picker.
  static DispatchAction openInChosen({
    required Uri inbound,
    required DispatchableSite site,
  }) {
    final target = _normalizeInbound(inbound) ?? inbound;
    return _openInExisting(site, target);
  }

  /// User picked "Send [host] (and subdomains) to [site]". The returned
  /// [DispatchBindAndOpen] tells the executor to mutate the site's
  /// claim list and then proceed with the same in-domain decision.
  static DispatchAction bindToSite({
    required Uri inbound,
    required DispatchableSite site,
  }) {
    final target = _normalizeInbound(inbound) ?? inbound;
    final additions = LinkRoutingService.claimsToAdoptUrl(target);
    return DispatchBindAndOpen(
      chosenSiteId: site.siteId,
      claimAdditions: additions,
      // Even after binding, the in-domain check is keyed off
      // `navigationDomain` (= getNormalizedDomain(initUrl)), which is
      // unchanged. So a bind from f-droid.org to a duckduckgo.com site
      // still produces an out-of-domain share → nested webview. This is
      // by design (LIR-011): claims drive routing of *future* arrivals;
      // the current arrival respects the existing site's session.
      followUp: _openInExisting(site, target),
    );
  }

  /// User picked a site from the "send / open to a site" list (LIR-010
  /// option 2). When [claimDomain] is true the chosen site adopts the URL's
  /// host as a claim before opening ([bindToSite]); when false (the default
  /// per discussion #439) the URL just opens in the chosen site and no claim
  /// is persisted ([openInChosen]). The opt-in is surfaced as the global
  /// `linkHandlingClaimDomains` setting.
  static DispatchAction sendToSite({
    required Uri inbound,
    required DispatchableSite site,
    required bool claimDomain,
  }) =>
      claimDomain
          ? bindToSite(inbound: inbound, site: site)
          : openInChosen(inbound: inbound, site: site);

  /// User picked "Create new site for [host]".
  static DispatchAction createNew({required Uri inbound}) {
    final target = _normalizeInbound(inbound) ?? inbound;
    final home = LinkRoutingService.strippedHomeUrl(target);
    if (home == null) {
      return const DispatchUnsupported('cannot strip path for create');
    }
    final claims = target.hasPort
        ? LinkRoutingService.claimsToAdoptUrl(target)
        : () {
            final base = getBaseDomain(target.host);
            return base.isEmpty
                ? const <DomainClaim>[]
                : [DomainClaim.baseDomain(base)];
          }();
    return DispatchCreateSite(
      home: home,
      fullUrl: target.toString(),
      initialClaims: claims,
    );
  }

  static DispatchAction _openInExisting(
    DispatchableSite site,
    Uri inbound,
  ) {
    final inDomain =
        getNormalizedDomain(inbound.toString()) == site.navigationDomain;
    if (!inDomain) {
      return DispatchOpenNested(
        siteId: site.siteId,
        url: inbound.toString(),
      );
    }
    final reset = site.incognito || site.alwaysOpenHome;
    return DispatchOpenInMain(
      siteId: site.siteId,
      url: inbound.toString(),
      disposeBeforeLoad: reset,
      wipeContainer: site.incognito,
      clearInMemoryCookies: site.incognito,
    );
  }

  static Uri? _normalizeInbound(Uri raw) {
    final unwrapped = raw.scheme.toLowerCase() == 'webspace'
        ? LinkRoutingService.parseWebspaceUri(raw)
        : raw;
    if (unwrapped == null) return null;
    if (unwrapped.scheme != 'http' && unwrapped.scheme != 'https') {
      return null;
    }
    if (unwrapped.host.isEmpty) return null;
    return unwrapped;
  }
}
