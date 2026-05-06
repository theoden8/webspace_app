/// Pure-Dart logic engine for dispatching inbound share/open intents to a
/// site (LIR-002, LIR-009, LIR-010, LIR-011, LIR-012). Mirrors the engine
/// pattern in `cookie_isolation.dart` / `site_activation_engine.dart`:
/// the engine returns a [DispatchAction] describing what should happen,
/// and `_WebSpacePageState` performs the IO/UI side-effects. No Flutter,
/// no platform channels, no setState — fully testable with fakes.
library;

import 'package:webspace/services/link_routing_service.dart';
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
/// main session is not clobbered.
class DispatchOpenNested extends DispatchAction {
  final String siteId;
  final String url;
  const DispatchOpenNested({required this.siteId, required this.url});
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
  const DispatchShowPicker({
    required this.winnerSiteIds,
    required this.offerBind,
    required this.offerCreate,
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
