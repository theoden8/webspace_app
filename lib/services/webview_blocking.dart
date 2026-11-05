
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/webkit_block_reports.dart';
import 'package:webspace/services/webview_config.dart';

void logSiteIcon(String message) =>
    LogTag.siteIcon.debug(message);

/// Whether the site's own blockers let a request for one of its page icons
/// through: the DNS level and filter lists its webview applies to an image
/// the page loads (ICON-013).
bool pageIconRequestAllowed(
  WebViewConfig config, {
  required Uri target,
  required String documentUrl,
  String requestType = 'image',
}) =>
    _verdictFor(
      config,
      query: UrlQuery(target.toString(),
          sourceUrl: documentUrl, requestType: requestType),
    ) is Allowed;

final class _LiveBlockLists implements BlockLists {
  const _LiveBlockLists();

  @override
  bool dnsBlocksUrl(String url, {required int level}) =>
      DnsBlockService.instance.isBlockedAtLevel(url, level: level);

  @override
  bool dnsBlocksHost(String host, {required int level}) =>
      DnsBlockService.instance.isHostBlockedAtLevel(host, level: level);

  @override
  bool abpBlocksUrl(String url,
          {required String sourceUrl, required String requestType}) =>
      ContentBlockerService.instance
          .isBlocked(url, sourceUrl: sourceUrl, requestType: requestType);

  @override
  bool abpBlocksHost(String host) =>
      ContentBlockerService.instance.isHostBlocked(host);

  @override
  String? abpRedirect(String url,
          {required String sourceUrl, required String requestType}) =>
      ContentBlockerService.instance
          .redirectFor(url, sourceUrl: sourceUrl, requestType: requestType);
}

BlockVerdict _verdictFor(WebViewConfig config, {required BlockQuery query}) =>
    BlockDecision.decide(query,
        policy: config.blockPolicy, lists: const _LiveBlockLists());

/// [_verdictFor], counted in the site's block stats.
BlockVerdict judgeAndRecord(WebViewConfig config,
    {required BlockQuery query}) {
  final verdict = _verdictFor(config, query: query);
  _record(config, query: query, verdict: verdict);
  return verdict;
}

/// The verdict for a navigation, counted only when it stops it: one that
/// goes ahead is counted where its document loads, by the native
/// interceptor on Android and the resource observer elsewhere (CB-012).
BlockVerdict judgeNavigation(WebViewConfig config,
    {required UrlQuery query}) {
  final verdict = _verdictFor(config, query: query);
  if (verdict.source != null) _record(config, query: query, verdict: verdict);
  return verdict;
}

void _record(WebViewConfig config,
        {required BlockQuery query, required BlockVerdict verdict}) =>
    DnsBlockService.instance
        .recordVerdict(config.posture.siteId, query: query, verdict: verdict);

UrlQuery _asked(PageRequest request, {required String sourceUrl}) =>
    UrlQuery(request.url,
        sourceUrl: sourceUrl, requestType: request.requestType);

/// The verdict for a request the WebKit interceptor asks about, counted in
/// the site's block stats where [countsForPage] counts it.
BlockVerdict judgePageAsk(WebViewConfig config,
    {required PageRequest request, required String sourceUrl}) {
  final query = _asked(request, sourceUrl: sourceUrl);
  final verdict = _verdictFor(config, query: query);
  if (countsForPage(request,
      verdict: verdict, webKitReports: WebKitBlockReports.active)) {
    _record(config, query: query, verdict: verdict);
  }
  return verdict;
}

/// Counts what the WebKit interceptor reports without asking: a block it
/// answered from its cache or a load it saw fail, when a list names it and
/// [countsForPage] counts it, and a block WebKit's rule lists made, as
/// [BlockDecision.reported] attributes it.
void recordPageReport(WebViewConfig config,
    {required PageReport report, required String sourceUrl}) {
  switch (report) {
    case PageSaw(:final request):
      final query = _asked(request, sourceUrl: sourceUrl);
      final verdict = _verdictFor(config, query: query);
      if (countsForPage(request,
          verdict: verdict, webKitReports: WebKitBlockReports.active)) {
        _record(config, query: query, verdict: verdict);
      }
    case WebKitBlocked(:final url):
      if (BlockDecision.reported(url,
              sourceUrl: sourceUrl,
              policy: config.blockPolicy,
              lists: const _LiveBlockLists())
          case (:final query, :final verdict)) {
        _record(config, query: query, verdict: verdict);
      }
  }
}

/// [count] requests the page loaded from [host], by WebKit's resource
/// timing: they went out, so they count as allowed whatever a list says of
/// the host.
void recordPageLoads(WebViewConfig config,
        {required String host, required int count}) =>
    DnsBlockService.instance.recordVerdict(config.posture.siteId,
        query: HostQuery(host), verdict: const Allowed(), count: count);
