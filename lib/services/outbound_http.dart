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
// buildPageSteeredClient is hidden: it is the sole producer of a page-steered
// client, and only this library (via pageSteeredClient) may name it, so no
// caller reached through the re-export can build one (SEC-049).
export 'package:webspace/services/outbound_http_web.dart'
    if (dart.library.io) 'package:webspace/services/outbound_http_io.dart'
    hide buildPageSteeredClient;

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
}

/// Drape the always-on DNT/Sec-GPC headers over a built client, as the
/// [_DoNotTrackOutboundHttpFactory] does for [clientFor]. The page-steered build
/// does not go through that wrapper (it is not a factory method), so
/// [pageSteeredClient] drapes it here.
OutboundClient _withDoNotTrack(OutboundClient built) =>
    built is OutboundClientReady
        ? OutboundClientReady(DoNotTrackClient(built.client))
        : built;

/// A client for an outbound call a loaded page can steer, which judges the
/// destination address as it connects (SEC-049). It is built only by
/// `buildPageSteeredClient`, which the public re-export hides, and wrapped only
/// by [pageSteeredClient] (the `._` constructor is private to this library), so
/// no caller outside the seam can make or name a page-steered client. Its client
/// is read only by [followPageSteered], the one function this library lets touch
/// [_result]. The two together are a type: a page-steered client cannot be built
/// outside the seam and cannot be driven except through the follower, which
/// follows redirects per hop so a rebinding or redirecting private target is
/// judged on every route, not just the first hop and not only under DEFAULT. That
/// the fetchers route page-chosen URLs through the follower rather than the
/// general [OutboundHttpFactory.clientFor] is the remaining
/// `page_steered_outbound_reach` gate.
class PageSteeredHttp {
  const PageSteeredHttp._(this._result);

  /// The sealed build result: [OutboundClientReady] carries the guarded client,
  /// [OutboundClientBlocked] says why none could be made, exactly as
  /// [OutboundHttpFactory.clientFor]'s result. Library-private: [followPageSteered]
  /// is the only reader, so no caller holds the client to send through it.
  final OutboundClient _result;

  /// Close the guarded client if one was built, cutting any socket it holds.
  /// The only thing a holder of a [PageSteeredHttp] may do besides hand it to
  /// [followPageSteered]: so a caller that reuses one client across several
  /// fetches (the favicon discovery) can release it when done, yet still cannot
  /// reach the client to send through it.
  void close() {
    if (_result case OutboundClientReady(:final client)) client.close();
  }
}

/// Build the [PageSteeredHttp] client for [route], the one producer of the type.
/// [allowPrivateHost] is the single host whose own private address the guard
/// permits (a page-linked resource's document host). Builds through the hidden
/// `buildPageSteeredClient` and drapes the always-on DNT/Sec-GPC headers like
/// every other outbound seam.
PageSteeredHttp pageSteeredClient(ProxyRoute route, {String? allowPrivateHost}) =>
    PageSteeredHttp._(_withDoNotTrack(buildPageSteeredClient(_factory,
        route: route, allowPrivateHost: allowPrivateHost)));

/// What [followPageSteered] produced: the value its [PageSteeredFollow.read] made
/// from the final response, or a refusal carrying [PageSteeredRefused.reason]
/// (the client could not be built, a hop failed [PageSteeredFollow.permit], or
/// the chain outran [PageSteeredFollow.maxRedirects]).
sealed class PageSteeredOutcome<T> {
  const PageSteeredOutcome();
}

/// The fetch reached a final response and [PageSteeredFollow.read] read it.
final class PageSteeredValue<T> extends PageSteeredOutcome<T> {
  const PageSteeredValue(this.value);
  final T value;
}

/// Why a [PageSteeredRefused] carries no value, so a caller can tell a proxy it
/// could not honour (worth a warning) from a page simply naming a target the
/// guard declines (expected, usually silent).
enum PageSteeredRefusal {
  /// The guarded client could not be built: the proxy could not be honoured, so
  /// no request was made (fail-closed).
  clientUnavailable,

  /// The initial URL failed [PageSteeredFollow.permit].
  url,

  /// A redirect target failed permit, stepped https down to http, or the chain
  /// outran [PageSteeredFollow.maxRedirects].
  redirect,
}

/// No value: the guarded client could not be built, a hop was refused, or the
/// redirect chain was too long ([kind] says which). [reason] is a short
/// technical detail a caller may log or localize; it is never a response body.
final class PageSteeredRefused<T> extends PageSteeredOutcome<T> {
  const PageSteeredRefused(this.reason, {required this.kind});
  final PageSteeredRefusal kind;
  final String reason;
}

/// The HTTP method [followPageSteered] issues each hop.
enum PageSteeredMethod {
  get,
  head;

  String get token => switch (this) {
        PageSteeredMethod.get => 'GET',
        PageSteeredMethod.head => 'HEAD',
      };
}

/// Everything [followPageSteered] needs beyond the guarded client and the URL:
/// how to judge each hop, how to read the final response, and the caps. Bundled
/// so the follower takes the client, the URL and this, not a parameter list.
class PageSteeredFollow<T> {
  const PageSteeredFollow({
    required this.permit,
    required this.read,
    this.method = PageSteeredMethod.get,
    this.maxRedirects = 5,
    this.forbidHttpsDowngrade = false,
    this.timeout,
    this.onRedirect,
    this.userAgent,
  });

  /// Whether the fetch may reach [target] ([target] is the initial URL, then
  /// each redirect destination). The guarded connect already judges every hop's
  /// resolved address; this is the caller's own policy on top (scheme, site
  /// blockers, the resolving range check) — defense in depth, run for the first
  /// URL and again before each redirect is taken.
  final Future<bool> Function(Uri target) permit;

  /// Reads the final (non-redirect) response into the caller's value. The
  /// follower has already judged and connected every hop; this only consumes the
  /// body (as a string, capped bytes, or a status probe). The response's
  /// `request.url` is the final hop's URL.
  final Future<T> Function(http.StreamedResponse response) read;

  final PageSteeredMethod method;

  final int maxRedirects;

  /// Refuse a redirect that steps an https hop down to http, so a page cannot
  /// use a redirect to drop the fetch off TLS (artwork, page-linked icons).
  final bool forbidHttpsDowngrade;

  /// A deadline for the whole exchange, every hop and the body read. The
  /// follower applies it where it can close the client, so a timeout cuts the
  /// socket rather than leaving an unbounded body draining in the background.
  /// A caller must pass it here rather than wrapping the call in `.timeout`.
  final Duration? timeout;

  /// Called for each accepted redirect with its destination, for a caller that
  /// tracks the chain (the favicon finder's `/favicon.ico` origins).
  final void Function(Uri to)? onRedirect;

  /// The User-Agent each hop sends (the value, not a client wrapper, so caller
  /// code never touches the guarded client). Resolved per hop and set only when
  /// the request has no User-Agent of its own, matching [SiteUserAgentClient].
  final Future<String?> Function()? userAgent;
}

bool _isPageSteeredRedirect(int status) =>
    status == 301 ||
    status == 302 ||
    status == 303 ||
    status == 307 ||
    status == 308;

/// Follow a page-steered fetch's redirects by hand — the ONLY place that does
/// (SEC-049, BUG-012). Each hop, the initial [url] and every `Location`, is a
/// fresh request through the guarded connect built from [route] (with the
/// client's own redirect-following OFF), so under every route (not just DEFAULT,
/// not just the first hop) each hop's address is judged before a byte is sent.
/// This is the one consumer of a [PageSteeredHttp]: its client is read nowhere
/// else (the field is library-private), so once a page-steered client is built
/// it cannot be driven except through this per-hop judging. The initial [url] is
/// judged by [PageSteeredFollow.permit] before any client is built, so a page
/// naming an unreachable target opens no connection. [allowPrivateHost] is the
/// one host whose own private address is allowed (a page-linked resource's
/// document host). The client is closed when done — on a normal return, a
/// refusal, or [PageSteeredFollow.timeout] firing — which cuts any body still
/// arriving; [PageSteeredFollow.read] has consumed the final body by a normal
/// return. A caller making several fetches that should share one connection pool
/// uses [followPageSteeredReusing] instead.
Future<PageSteeredOutcome<T>> followPageSteered<T>(
  ProxyRoute route, {
  required Uri url,
  required PageSteeredFollow<T> follow,
  String? allowPrivateHost,
}) =>
    _runFollow(() => pageSteeredClient(route, allowPrivateHost: allowPrivateHost),
        url: url, follow: follow, close: true);

/// Follow a page-steered fetch using [client], a [PageSteeredHttp] the caller
/// built once (through [pageSteeredClient]) and closes itself, so several
/// fetches in one operation (the favicon discovery) share a connection pool
/// rather than paying a fresh handshake — most of the budget under Tor or SOCKS
/// — per fetch. [client] is used but never closed here; it already carries its
/// own `allowPrivateHost`. Every hop is judged and pinned exactly as in
/// [followPageSteered]; this is the only other consumer of a [PageSteeredHttp],
/// and it still cannot reach the client to send outside the per-hop loop.
Future<PageSteeredOutcome<T>> followPageSteeredReusing<T>(
  PageSteeredHttp client, {
  required Uri url,
  required PageSteeredFollow<T> follow,
}) =>
    _runFollow(() => client, url: url, follow: follow, close: false);

/// Build one guarded client, run [body] with it, then close it however [body]
/// returns — for a caller that makes several page-steered fetches for one
/// operation (the favicon discovery: the page, then an icon per declared link)
/// and wants them to share a connection pool rather than pay a handshake each.
/// [body] drives the client only through [followPageSteeredReusing]; it cannot
/// reach the client to send through it (the client field is library-private).
/// This keeps [pageSteeredClient] internal to this seam, so a reusing fetcher
/// names this helper, never the build.
Future<T> withPageSteeredClient<T>(
  ProxyRoute route, {
  String? allowPrivateHost,
  required Future<T> Function(PageSteeredHttp client) body,
}) async {
  final client = pageSteeredClient(route, allowPrivateHost: allowPrivateHost);
  try {
    return await body(client);
  } finally {
    client.close();
  }
}

/// The shared body of the two entry points: judge [url] FIRST, then take the
/// client out of [build] (so a refused URL builds no client and opens no
/// connection — the media/icon "dropped without a fetch" contract), follow every
/// hop, and close the client when [close] (the building entry owns it; a reused
/// one does not). [build] is a thunk, not a value, precisely so the build stays
/// after the permit check rather than running as an eager argument.
Future<PageSteeredOutcome<T>> _runFollow<T>(
  PageSteeredHttp Function() build, {
  required Uri url,
  required PageSteeredFollow<T> follow,
  required bool close,
}) async {
  if (!await follow.permit(url)) {
    return const PageSteeredRefused('blocked URL',
        kind: PageSteeredRefusal.url);
  }
  final http.Client client;
  switch (build()._result) {
    case OutboundClientBlocked(:final reason):
      return PageSteeredRefused(reason,
          kind: PageSteeredRefusal.clientUnavailable);
    case OutboundClientReady(client: final ready):
      client = ready;
  }
  try {
    Future<PageSteeredOutcome<T>> run() async {
      var target = url;
      for (var hop = 0;; hop++) {
        final request = http.Request(follow.method.token, target)
          ..followRedirects = false;
        final agent = follow.userAgent == null ? null : await follow.userAgent!();
        if (agent != null) request.headers.putIfAbsent('User-Agent', () => agent);
        final response = await client.send(request);
        final location = response.headers['location'];
        if (_isPageSteeredRedirect(response.statusCode) &&
            location != null &&
            location.isNotEmpty) {
          // Let the forced close cut a 3xx body still arriving; draining it
          // would surface the close as an uncaught ClientException.
          unawaited(response.stream.listen(null).cancel());
          final next = target.resolve(location);
          final downgrades = follow.forbidHttpsDowngrade &&
              target.scheme == 'https' &&
              next.scheme == 'http';
          if (hop >= follow.maxRedirects ||
              downgrades ||
              !await follow.permit(next)) {
            return const PageSteeredRefused('blocked redirect',
                kind: PageSteeredRefusal.redirect);
          }
          follow.onRedirect?.call(next);
          target = next;
          continue;
        }
        return PageSteeredValue(await follow.read(_plainStreamed(response)));
      }
    }

    final timeout = follow.timeout;
    return timeout == null ? await run() : await run().timeout(timeout);
  } finally {
    if (close) client.close();
  }
}

/// Re-wrap [r] as a plain [http.StreamedResponse] before handing it to
/// [PageSteeredFollow.read], so a read cannot downcast it to the transport's
/// `IOStreamedResponse` and `detachSocket()` the live connection out from under
/// the guard. `detachSocket` is not a method on the base type, so the common
/// call does not compile; the cast-based escape fails at run time instead of
/// handing back a raw socket (SEC-049). The body stream is the same object, so
/// the wrap is transparent to every read.
http.StreamedResponse _plainStreamed(http.StreamedResponse r) =>
    http.StreamedResponse(
      r.stream,
      r.statusCode,
      contentLength: r.contentLength,
      request: r.request,
      headers: r.headers,
      isRedirect: r.isRedirect,
      persistentConnection: r.persistentConnection,
      reasonPhrase: r.reasonPhrase,
    );

/// A [PageSteeredFollow.read] that streams the body to at most [maxBytes],
/// returning the bytes, or null when the answer is not a 200 or the body (by its
/// declared length or as it arrives) is over the cap. Shared by the fetchers
/// that take a byte budget (media-session artwork, page-linked icons).
Future<Uint8List?> Function(http.StreamedResponse) pageSteeredCappedBytes(
        int maxBytes) =>
    (response) async {
      if (response.statusCode != 200) return null;
      final length = response.contentLength;
      if (length != null && length > maxBytes) return null;
      final bytes = BytesBuilder(copy: false);
      await for (final chunk in response.stream) {
        bytes.add(chunk);
        if (bytes.length > maxBytes) return null;
      }
      return bytes.takeBytes();
    };

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
