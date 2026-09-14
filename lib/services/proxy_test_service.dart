import 'dart:async';

import 'package:http/http.dart' as http;

import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// What a connection test learned about a proxy configuration (PROXY-019).
enum ProxyTestOutcome {
  /// A response came back through the proxy. The proxy is reachable and,
  /// where credentials were supplied, accepted them.
  reachable,

  /// The proxy answered but refused the credentials (HTTP 407, or a SOCKS5
  /// authentication failure).
  authRejected,

  /// The proxy could not be reached, or dropped the connection.
  unreachable,

  /// Nothing came back before the deadline.
  timedOut,

  /// The outbound seam refused to build a client at all — a malformed
  /// address, or Tor not yet bootstrapped. Never a fallback to a direct
  /// connection: that would put the probe on the device IP.
  blocked,
}

class ProxyTestResult {
  const ProxyTestResult(this.outcome, {this.statusCode, this.detail});

  final ProxyTestOutcome outcome;

  /// Status of the response that came back, when one did.
  final int? statusCode;

  /// Operator-facing explanation. Never localized: it carries the
  /// underlying error text, which is what makes a failure diagnosable.
  final String? detail;
}

/// Default probe target. IANA's reserved example domain, and already the
/// host `ConnectivityService` resolves — reaching for a real site would tell
/// a third party which proxy the user is configuring.
final Uri kDefaultProxyTestTarget = Uri.parse('https://example.com');

/// Where to point the test for a site whose home URL is [siteUrl].
///
/// The site's own origin is the more honest target — it is the route the
/// user actually cares about — but only when the proxy is what carries it:
/// a private or loopback host is exempted from the proxy by PROXY-007, so
/// testing against one would report success without a single byte having
/// traversed the proxy.
Uri proxyTestTarget(String? siteUrl) {
  if (siteUrl == null || siteUrl.isEmpty) return kDefaultProxyTestTarget;
  final parsed = Uri.tryParse(siteUrl);
  if (parsed == null) return kDefaultProxyTestTarget;
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    return kDefaultProxyTestTarget;
  }
  if (parsed.host.isEmpty || isPrivateOrLoopbackHost(parsed.host)) {
    return kDefaultProxyTestTarget;
  }
  // Origin only. `replace` would leave the query and fragment delimiters
  // behind, and the path is the user's business, not the proxy's.
  return Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: '/',
  );
}

/// Ask [settings] to carry one request to [target] and report what happened.
///
/// [siteId] is the Tor stream-isolation tag, so a per-site test rides the
/// same circuit the site itself would (PROXY-011).
Future<ProxyTestResult> testProxyConnection(
  UserProxySettings settings, {
  required Uri target,
  String? siteId,
  Duration timeout = const Duration(seconds: 15),
}) async {
  final effective = resolveEffectiveProxy(settings, siteId: siteId);
  final client = outboundHttp.clientFor(effective);
  switch (client) {
    case OutboundClientBlocked(:final reason):
      return ProxyTestResult(ProxyTestOutcome.blocked, detail: reason);
    case OutboundClientReady(client: final http.Client probe):
      try {
        final request = http.Request('GET', target)..followRedirects = false;
        final response = await probe.send(request).timeout(timeout);
        // Nothing reads the body: a proxy that answered has answered the
        // question. Cancel without awaiting — that future settles only once
        // the transport is torn down, which is what `close()` below does
        // (`IOClient.close` forces open connections shut).
        unawaited(response.stream.listen(null).cancel());
        if (response.statusCode == 407) {
          return ProxyTestResult(
            ProxyTestOutcome.authRejected,
            statusCode: response.statusCode,
          );
        }
        return ProxyTestResult(
          ProxyTestOutcome.reachable,
          statusCode: response.statusCode,
        );
      } catch (e) {
        return _classify(e);
      } finally {
        probe.close();
      }
  }
}

/// Sort a thrown error into an outcome without importing `dart:io`.
///
/// This file sits under the settings screens' import closure, so it has to
/// compile for the web target (DESIGN-001) and cannot name `SocketException`
/// or `HandshakeException`. The distinctions that matter to the user survive
/// in the message: dart:io reports a refused CONNECT as
/// "Proxy failed to establish tunnel (407 ...)", and the SOCKS5 client
/// reports a rejected username/password as an authentication failure.
ProxyTestResult _classify(Object error) {
  if (error is TimeoutException) {
    return const ProxyTestResult(ProxyTestOutcome.timedOut);
  }
  final text = error.toString();
  final lower = text.toLowerCase();
  if (lower.contains('407') ||
      lower.contains('proxy authentication') ||
      lower.contains('authentication failed') ||
      lower.contains('auth failed')) {
    return ProxyTestResult(ProxyTestOutcome.authRejected, detail: text);
  }
  return ProxyTestResult(ProxyTestOutcome.unreachable, detail: text);
}

/// Log a completed test. Type and address are PII-safe (`describeForLogs`
/// reduces the credentials to booleans); the outcome is what the user will
/// be asked to paste when a proxy misbehaves.
void logProxyTest(UserProxySettings settings, ProxyTestResult result) {
  LogService.instance.log(
    'Proxy',
    'Connection test: ${settings.describeForLogs()} '
        'outcome=${result.outcome.name} status=${result.statusCode ?? '-'}',
    level: result.outcome == ProxyTestOutcome.reachable
        ? LogLevel.info
        : LogLevel.error,
    sensitivity: LogSensitivity.sensitive,
  );
}
