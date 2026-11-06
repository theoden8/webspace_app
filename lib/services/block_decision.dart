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
  const Blocked(this.source, {this.alsoAbp = false})
      : assert(!alsoAbp || source == BlockSource.dns,
            'only a DNS block is one the filter lists could also have stopped');

  @override
  final BlockSource source;

  /// For a DNS block, whether the filter lists would have stopped the
  /// request too. It still counts against DNS alone; this shows how far the
  /// lists reach.
  final bool alsoAbp;
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
  /// the order Android's native interceptor takes too. While the site keeps
  /// content blocking on, the filter lists are asked about a DNS block as
  /// well, only to say whether they would have stopped it too
  /// ([Blocked.alsoAbp], CB-012), and decide what DNS let through.
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
    if (dns) {
      return Blocked(BlockSource.dns,
          alsoAbp: policy.contentBlock && _abpBlocks(query, lists: lists));
    }
    if (!policy.contentBlock || !_abpBlocks(query, lists: lists)) {
      return const Allowed();
    }
    return switch (query) {
      HostQuery() => const Blocked(BlockSource.abp),
      UrlQuery(:final url, :final sourceUrl, :final requestType) => switch (
            lists.abpRedirect(url,
                sourceUrl: sourceUrl, requestType: requestType)) {
          null => const Blocked(BlockSource.abp),
          final stub => Redirect(stub),
        },
    };
  }

  /// A request WebKit's rule lists blocked, which WebKit reports by URL
  /// alone (CB-023), judged in [decide]'s order: DNS's when DNS names it,
  /// else the filter lists', under the first request type a rule of theirs
  /// matches. Null when no list names it, so a report a page forged records
  /// no block a list did not make.
  static ({UrlQuery query, Blocked verdict})? reported(
    String url, {
    required String sourceUrl,
    required BlockPolicy policy,
    required BlockLists lists,
  }) {
    UrlQuery as(EngineRequestType type) =>
        UrlQuery(url, sourceUrl: sourceUrl, requestType: type.name);
    final level = policy.dnsLevel;
    if (level > kDnsLevelOff && lists.dnsBlocksUrl(url, level: level)) {
      return (
        query: as(EngineRequestType.other),
        verdict: Blocked(BlockSource.dns, alsoAbp: policy.contentBlock),
      );
    }
    if (!policy.contentBlock) return null;
    for (final type in EngineRequestType.values) {
      final query = as(type);
      if (_abpBlocks(query, lists: lists)) {
        return (query: query, verdict: const Blocked(BlockSource.abp));
      }
    }
    return null;
  }

  static bool _abpBlocks(BlockQuery query, {required BlockLists lists}) =>
      switch (query) {
        HostQuery(:final host) => lists.abpBlocksHost(host),
        UrlQuery(:final url, :final sourceUrl, :final requestType) =>
          lists.abpBlocksUrl(url,
              sourceUrl: sourceUrl, requestType: requestType),
      };
}

/// The request types the engine knows, by the names it takes: the ones
/// Android's interceptor derives from `Sec-Fetch-Dest` and the WebKit
/// interceptor from the element or call that loads.
enum EngineRequestType {
  script,
  stylesheet,
  image,
  font,
  media,
  subdocument,
  xhr,
  websocket,
  document,
  other,
}

/// A request the WebKit interceptor asks about or reports. [issued] marks
/// one WebKit had sent before the page saw it (an element already in the
/// page), whose fate WebKit's own rule lists decided.
typedef PageRequest = ({String url, String requestType, bool issued});

/// What the WebKit interceptor reports without asking (`blockRecordBatch`).
sealed class PageReport {
  const PageReport();

  /// The entry the page sent, or null for one that is not a report.
  static PageReport? parse(Object? entry) => switch (entry) {
        {'why': 'webkit', 'url': final String url} => WebKitBlocked(url),
        {
          'why': 'cached' || 'failed',
          'url': final String url,
          'type': final String type,
          'issued': final bool issued,
        } =>
          PageSaw((url: url, requestType: type, issued: issued)),
        _ => null,
      };
}

/// A block the page answered from its cache, or a load the page saw fail.
final class PageSaw extends PageReport {
  const PageSaw(this.request);

  final PageRequest request;
}

/// A request WebKit's rule lists blocked, by WebKit's own report (CB-023).
final class WebKitBlocked extends PageReport {
  const WebKitBlocked(this.url);

  final String url;
}

/// One ask of a `blockCheckBatch`, or null for an entry that is none.
PageRequest? parsePageAsk(Object? entry) => switch (entry) {
      {
        'url': final String url,
        'type': final String type,
        'issued': final bool issued,
      } =>
        (url: url, requestType: type, issued: issued),
      _ => null,
    };

/// Whether the site's stats count [verdict] for a request the page asked
/// about or reported (CB-012). Each request counts once, where its outcome is
/// known: one let through counts where it loads (the resource observer), so
/// never here. A block made before the request went out is the
/// interceptor's, so it counts. One WebKit had already issued was blocked,
/// if at all, by WebKit's rule lists, which hold the filter lists and not the
/// DNS list: only a verdict those lists share counts, and none where WebKit
/// reports its blocks itself.
bool countsForPage(
  PageRequest request, {
  required BlockVerdict verdict,
  required bool webKitReports,
}) =>
    switch (verdict) {
      Allowed() => false,
      Redirect() ||
      Blocked(source: BlockSource.abp) ||
      Blocked(alsoAbp: true) =>
        !request.issued || !webKitReports,
      Blocked() => !request.issued,
    };

/// The WebKit interceptor's reply for each ask of one batch, in order: false
/// lets it go, true drops it, a string is the `data:` URL a `$redirect=` rule
/// serves instead. An entry that is no ask is let go: nothing loads from it.
List<Object> pageBlockReplies(
  List<Object?> asks, {
  required BlockVerdict Function(PageRequest request) judge,
}) =>
    [
      for (final ask in asks)
        if (parsePageAsk(ask) case final request?)
          switch (judge(request)) {
            Allowed() => false,
            Blocked() => true,
            Redirect(:final url) => url,
          }
        else
          false,
    ];
