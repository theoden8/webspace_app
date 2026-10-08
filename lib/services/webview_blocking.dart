
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/log_service.dart';
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
  DnsBlockService.instance
      .recordVerdict(config.posture.siteId, query: query, verdict: verdict);
  return verdict;
}
