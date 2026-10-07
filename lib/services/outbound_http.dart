// Public entry point for Dart-side outbound HTTP. Re-exports the neutral types
// plus whichever platform factory this build has, and owns the swappable global
// factory that tests override.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http_types.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';
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
  OutboundClient clientFor(UserProxySettings settings) {
    final result = inner.clientFor(settings);
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

/// The server answered 200; [response] holds the whole body.
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
/// abandoned as it arrives.
Future<AppProxyFetch> fetchViaAppProxy(
  Uri url, {
  required String tag,
  Duration timeout = const Duration(seconds: 15),
  int? maxBytes,
  Map<String, String> headers = const {},
}) async {
  if (url.scheme != 'https' && url.scheme != 'http') {
    return _fetchFailed(tag, url, 'not an http(s) URL');
  }
  final http.Client client;
  switch (outboundHttp.clientFor(GlobalOutboundProxy.current)) {
    case OutboundClientBlocked(:final reason):
      LogService.instance.log(tag, 'Skipped download: $reason',
          level: LogLevel.warning);
      return FetchRefused(reason);
    case OutboundClientReady(client: final ready):
      client = ready;
  }
  try {
    return await _fetch(client, url, tag, maxBytes, headers).timeout(timeout);
  } on Exception catch (e) {
    // A timeout, or the proxy's, socket's or TLS layer's own failure, whose
    // types differ by platform. Errors are bugs and still reach the caller.
    return _fetchFailed(tag, url, '$e');
  } finally {
    client.close();
  }
}

Future<AppProxyFetch> _fetch(
  http.Client client,
  Uri url,
  String tag,
  int? maxBytes,
  Map<String, String> headers,
) async {
  final streamed =
      await client.send(http.Request('GET', url)..headers.addAll(headers));
  if (streamed.statusCode != 200) {
    unawaited(streamed.stream.listen(null).cancel());
    return _fetchFailed(tag, url, 'HTTP ${streamed.statusCode}');
  }
  final body = BytesBuilder(copy: false);
  await for (final chunk in streamed.stream) {
    body.add(chunk);
    if (maxBytes != null && body.length > maxBytes) {
      return _fetchFailed(tag, url, 'larger than $maxBytes bytes');
    }
  }
  return Fetched(http.Response.bytes(
    body.takeBytes(),
    streamed.statusCode,
    request: streamed.request,
    headers: streamed.headers,
  ));
}

FetchFailed _fetchFailed(String tag, Uri url, String reason) {
  LogService.instance.log(tag, 'Download from ${url.host} failed: $reason',
      level: LogLevel.error);
  return FetchFailed(reason);
}
