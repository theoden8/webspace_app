// Public entry point for Dart-side outbound HTTP. Re-exports the neutral types
// plus whichever platform factory this build has, and owns the swappable global
// factory that tests override.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/outbound_http_web.dart'
    if (dart.library.io) 'package:webspace/services/outbound_http_io.dart';

export 'package:webspace/services/outbound_http_types.dart';
export 'package:webspace/services/outbound_http_web.dart'
    if (dart.library.io) 'package:webspace/services/outbound_http_io.dart';

OutboundHttpFactory _factory = const DefaultOutboundHttpFactory();

/// Wrapping factory: forwards to [inner] for proxy/connection setup, then
/// drapes the always-on DNT/Sec-GPC client over the result. Sandwiched
/// between the public [outboundHttp] getter and the underlying
/// [DefaultOutboundHttpFactory] so every caller — production or test
/// (when not overriding the factory) — gets the privacy headers.
class _DoNotTrackOutboundHttpFactory implements OutboundHttpFactory {
  final OutboundHttpFactory inner;
  const _DoNotTrackOutboundHttpFactory(this.inner);

  @override
  OutboundClient clientFor(
    ProxyRoute route, {
    BodyEncoding encoding = BodyEncoding.decoded,
  }) {
    final result = inner.clientFor(route, encoding: encoding);
    if (result is OutboundClientReady) {
      return OutboundClientReady(DoNotTrackClient(result.client));
    }
    return result;
  }

  @override
  OutboundClient pageSteeredClientFor(ProxyRoute route,
      {String? allowPrivateHost}) {
    final result =
        inner.pageSteeredClientFor(route, allowPrivateHost: allowPrivateHost);
    if (result is OutboundClientReady) {
      return OutboundClientReady(DoNotTrackClient(result.client));
    }
    return result;
  }
}

/// A client for an outbound call a loaded page can steer, which judges the
/// destination address as it connects (SEC-049). Only [pageSteeredClient]
/// constructs one — the `._` constructor is private to this library — so a
/// [PageSteeredHttp] in hand provably came from the guarded path. Which fetchers
/// route through it, rather than the raw [OutboundHttpFactory.clientFor], is held
/// by the `page_steered_outbound_reach` structural gate, not the compiler: a
/// fetcher that reverted to `clientFor` would still compile, and the gate is what
/// catches it. Lifting that to a type the four page-steerable fetchers (user
/// scripts, media-session artwork, page-linked icons, favicons) take in their
/// signatures is the LEAK-002 type-debt (`docs/security/policy_debt.tsv`).
class PageSteeredHttp {
  const PageSteeredHttp._(this.result);

  /// The sealed build result: [OutboundClientReady] carries the guarded client
  /// (the caller MUST close it), [OutboundClientBlocked] says why none could be
  /// made, exactly as [OutboundHttpFactory.clientFor]'s result.
  final OutboundClient result;
}

/// Build the [PageSteeredHttp] client for [route], the one producer of the
/// type. [allowPrivateHost] is the single host whose own private address the
/// guard permits (a page-linked resource's document host). Drapes the always-on
/// DNT/Sec-GPC headers like every other outbound seam.
PageSteeredHttp pageSteeredClient(ProxyRoute route, {String? allowPrivateHost}) =>
    PageSteeredHttp._(
        outboundHttp.pageSteeredClientFor(route, allowPrivateHost: allowPrivateHost));

/// Global outbound HTTP factory. Use this from every Dart-side HTTP call
/// that can carry user-identifying traffic.
OutboundHttpFactory get outboundHttp => _DoNotTrackOutboundHttpFactory(_factory);

@visibleForTesting
set outboundHttp(OutboundHttpFactory f) => _factory = f;

/// Restore the default factory. Call from `tearDown` in tests.
@visibleForTesting
void resetOutboundHttp() => _factory = const DefaultOutboundHttpFactory();

/// What [fetchViaAppProxy] got back. Every outcome but [Fetched] is already
/// logged under the caller's tag.
sealed class AppProxyFetch {
  const AppProxyFetch();
}

/// The server answered 200, or 206 to a request for the body's first bytes;
/// [response] holds the whole body, or as much of it as was asked for.
final class Fetched extends AppProxyFetch {
  const Fetched(this.response);
  final http.Response response;
}

/// The app-wide proxy cannot be honoured, so no request was made: going
/// direct instead would leak the device IP.
final class FetchRefused extends AppProxyFetch {
  const FetchRefused(this.reason);
  final String reason;
}

/// The request was made and brought back nothing usable: another status,
/// a transport failure or timeout, or a body over the size limit.
final class FetchFailed extends AppProxyFetch {
  const FetchFailed(this.reason);
  final String reason;
}

/// What gives up on a fetch that has not finished.
sealed class FetchTimeout {
  const FetchTimeout(this.limit);
  final Duration limit;
}

/// The whole exchange, body included, within [limit].
final class TotalTimeout extends FetchTimeout {
  const TotalTimeout(super.limit);
}

/// [limit] without a byte: waiting for the answer, then between parts of
/// the body. A download takes what its route needs while it moves, so a
/// package through Tor arrives however slowly it comes.
final class IdleTimeout extends FetchTimeout {
  const IdleTimeout(super.limit);
}

/// GET [url] through the app-wide outbound proxy, for the downloaded data
/// the services keep (blocklists, rules, datasets), giving up as [timeout]
/// says; a body longer than [maxBytes] is abandoned as it arrives. With
/// [firstBytes] only the body's start is wanted: the request asks for that
/// range, and the read stops once that much has arrived, also from a server
/// that sends the whole body.
Future<AppProxyFetch> fetchViaAppProxy(
  Uri url, {
  required LogTag tag,
  FetchTimeout timeout = const TotalTimeout(Duration(seconds: 15)),
  int? maxBytes,
  int? firstBytes,
  Map<String, String> headers = const {},
}) async {
  assert(firstBytes == null || firstBytes > 0, 'a range has a first byte');
  if (url.scheme != 'https' && url.scheme != 'http') {
    return _fetchFailed(tag, url: url, reason: 'not an http(s) URL');
  }
  final http.Client client;
  switch (outboundHttp.clientFor(OutboundProxy.app.resolved)) {
    case OutboundClientBlocked(:final reason):
      tag.warning('Skipped download: $reason');
      return FetchRefused(reason);
    case OutboundClientReady(client: final ready):
      client = ready;
  }
  // The transport's failures: package:http's own, the I/O failures it
  // passes through unwrapped (a TLS handshake, a SOCKS refusal), and a body
  // its declared encoding does not decode.
  try {
    final request = http.Request('GET', url)..headers.addAll(headers);
    if (firstBytes != null) {
      request.headers['Range'] = 'bytes=0-${firstBytes - 1}';
    }
    final exchange = _fetch(client,
        request: request,
        tag: tag,
        maxBytes: maxBytes,
        firstBytes: firstBytes,
        idle: switch (timeout) {
          IdleTimeout(:final limit) => limit,
          TotalTimeout() => null,
        });
    return await switch (timeout) {
      TotalTimeout(:final limit) => exchange.timeout(limit),
      IdleTimeout() => exchange,
    };
  } on http.ClientException catch (e) {
    return _fetchFailed(tag, url: url, reason: '$e');
  } on IOException catch (e) {
    return _fetchFailed(tag, url: url, reason: '$e');
  } on TimeoutException {
    final seconds = timeout.limit.inSeconds;
    return _fetchFailed(tag, url: url, reason: switch (timeout) {
      TotalTimeout() => 'not done within $seconds s',
      IdleTimeout() => 'nothing arrived for $seconds s',
    });
  } on FormatException catch (e) {
    return _fetchFailed(tag, url: url, reason: '$e');
  } finally {
    client.close();
  }
}

Future<AppProxyFetch> _fetch(
  http.Client client, {
  required http.Request request,
  required LogTag tag,
  required int? maxBytes,
  required int? firstBytes,
  required Duration? idle,
}) async {
  final url = request.url;
  final sent = client.send(request);
  final streamed = await (idle == null ? sent : sent.timeout(idle));
  final answered = streamed.statusCode == 200 ||
      (firstBytes != null && streamed.statusCode == 206);
  if (!answered) {
    unawaited(streamed.stream.listen(null).cancel());
    return _fetchFailed(tag, url: url, reason: 'HTTP ${streamed.statusCode}');
  }
  final body = BytesBuilder(copy: false);
  final parts = StreamIterator(streamed.stream);
  try {
    while (await (idle == null
        ? parts.moveNext()
        : parts.moveNext().timeout(idle))) {
      body.add(parts.current);
      if (firstBytes != null && body.length >= firstBytes) break;
      if (maxBytes != null && body.length > maxBytes) {
        return _fetchFailed(tag, url: url,
            reason: 'larger than $maxBytes bytes');
      }
    }
  } finally {
    // A body that stalled may never let a cancel finish.
    unawaited(parts.cancel());
  }
  return Fetched(http.Response.bytes(
    body.takeBytes(),
    streamed.statusCode,
    request: streamed.request,
    headers: streamed.headers,
  ));
}

FetchFailed _fetchFailed(LogTag tag,
    {required Uri url, required String reason}) {
  tag.error('Download from ${url.host} failed: $reason');
  return FetchFailed(reason);
}
