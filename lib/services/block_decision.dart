import 'package:webspace/services/dns_level_mask_engine.dart';

/// Which list stopped a request.
enum BlockSource { dns, abp }

/// What a site's blockers apply to every request it makes: one value, so a
/// toggle and the level it gates cannot disagree at a call site.
typedef BlockPolicy = ({int dnsLevel, bool contentBlock});

/// A request as the blockers judge it.
sealed class BlockQuery {
  const BlockQuery();
}

/// A full URL. [sourceUrl] is the page that made the request, so `$domain=`
/// rules apply; [requestType] is the engine's (`document`, `image`, ...).
final class UrlQuery extends BlockQuery {
  const UrlQuery(this.url, {required this.sourceUrl, required this.requestType});

  final String url;
  final String sourceUrl;
  final String requestType;
}

/// A bare host, which is all WebKit's stats observer reports.
final class HostQuery extends BlockQuery {
  const HostQuery(this.host);

  final String host;
}

sealed class BlockVerdict {
  const BlockVerdict();

  /// The list that stopped the request; null when it goes out.
  BlockSource? get source;
}

final class Allowed extends BlockVerdict {
  const Allowed();

  @override
  BlockSource? get source => null;
}

final class Blocked extends BlockVerdict {
  const Blocked(this.source);

  @override
  final BlockSource source;
}

/// The filter lists serve [url], a `data:` stub, in place of the request
/// (`$redirect=`, CB-010). Only a sub-resource can take one; anything else
/// treats it as a block.
final class Redirect extends BlockVerdict {
  const Redirect(this.url);

  final String url;

  @override
  BlockSource get source => BlockSource.abp;
}

/// The lookups behind a verdict.
abstract interface class BlockLists {
  bool dnsBlocksUrl(String url, {required int level});
  bool dnsBlocksHost(String host, {required int level});
  bool abpBlocksUrl(String url,
      {required String sourceUrl, required String requestType});
  bool abpBlocksHost(String host);
  String? abpRedirect(String url,
      {required String sourceUrl, required String requestType});
}

abstract final class BlockDecision {
  /// The one verdict every path that blocks or counts a request takes.
  ///
  /// DNS is asked first and wins when both lists match, so a request counts
  /// against one list (CB "Source attribution when DNS + ABP both match"),
  /// the order Android's native interceptor takes too. The filter lists are
  /// asked only about what DNS let through, and only when the site keeps
  /// content blocking on.
  static BlockVerdict decide(
    BlockQuery query, {
    required BlockPolicy policy,
    required BlockLists lists,
  }) {
    final level = policy.dnsLevel;
    final dns = level > kDnsLevelOff &&
        switch (query) {
          UrlQuery(:final url) => lists.dnsBlocksUrl(url, level: level),
          HostQuery(:final host) => lists.dnsBlocksHost(host, level: level),
        };
    if (dns) return const Blocked(BlockSource.dns);
    if (!policy.contentBlock) return const Allowed();
    switch (query) {
      case HostQuery(:final host):
        return lists.abpBlocksHost(host)
            ? const Blocked(BlockSource.abp)
            : const Allowed();
      case UrlQuery(:final url, :final sourceUrl, :final requestType):
        if (!lists.abpBlocksUrl(url,
            sourceUrl: sourceUrl, requestType: requestType)) {
          return const Allowed();
        }
        final stub = lists.abpRedirect(url,
            sourceUrl: sourceUrl, requestType: requestType);
        return stub == null ? const Blocked(BlockSource.abp) : Redirect(stub);
    }
  }
}
