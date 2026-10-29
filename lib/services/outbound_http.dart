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
  OutboundClient clientFor(ProxyRoute route) {
    final result = inner.clientFor(route);
    if (result is OutboundClientReady) {
      return OutboundClientReady(DoNotTrackClient(result.client));
    }
    return result;
  }
}

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

/// GET [url] through the app-wide outbound proxy, for the downloaded data
/// the services keep (blocklists, rules, datasets). [timeout] bounds the
/// whole exchange, body included; a body longer than [maxBytes] is
/// abandoned as it arrives. With [firstBytes] only the body's start is
/// wanted: the request asks for that range, and the read stops once that
/// much has arrived, also from a server that sends the whole body.
Future<AppProxyFetch> fetchViaAppProxy(
  Uri url, {
  required LogTag tag,
  Duration timeout = const Duration(seconds: 15),
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
    return await _fetch(client,
            request: request,
            tag: tag,
            maxBytes: maxBytes,
            firstBytes: firstBytes)
        .timeout(timeout);
  } on http.ClientException catch (e) {
    return _fetchFailed(tag, url: url, reason: '$e');
  } on IOException catch (e) {
    return _fetchFailed(tag, url: url, reason: '$e');
  } on TimeoutException catch (e) {
    return _fetchFailed(tag, url: url, reason: '$e');
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
}) async {
  final url = request.url;
  final streamed = await client.send(request);
  final answered = streamed.statusCode == 200 ||
      (firstBytes != null && streamed.statusCode == 206);
  if (!answered) {
    unawaited(streamed.stream.listen(null).cancel());
    return _fetchFailed(tag, url: url, reason: 'HTTP ${streamed.statusCode}');
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in streamed.stream) {
    body.add(chunk);
    if (firstBytes != null && body.length >= firstBytes) break;
    if (maxBytes != null && body.length > maxBytes) {
      return _fetchFailed(tag, url: url, reason: 'larger than $maxBytes bytes');
    }
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
