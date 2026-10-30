import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'package:webspace/platform/host_platform.dart' show IOException;
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// What a connection test learned about a proxy configuration (PROXY-019).
enum ProxyTestOutcome {
  /// A response came back through the proxy. The proxy is reachable and,
  /// where credentials were supplied, accepted them.
  reachable,

  /// The Tor check answered that the request left from a Tor exit, at
  /// [ProxyTestResult.seenFrom].
  torExit,

  /// The Tor check answered that the request did not come from a Tor exit:
  /// the route reaches the web, but not through Tor.
  notTorExit,

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
  const ProxyTestResult(this.outcome,
      {this.response, this.seenFrom, this.detail})
      : assert(
            (seenFrom != null) ==
                (outcome == ProxyTestOutcome.torExit ||
                    outcome == ProxyTestOutcome.notTorExit),
            'a Tor verdict, and only one, names the address the check saw');

  final ProxyTestOutcome outcome;

  /// The response that came back, when one did: its status and the host
  /// that sent it.
  final ({int status, String host})? response;

  /// The address the Tor check saw the request come from.
  final String? seenFrom;

  /// Operator-facing explanation. Never localized: it carries the
  /// underlying error text, which is what makes a failure diagnosable.
  final String? detail;
}

/// Default probe target. IANA's reserved example domain, and already the
/// host `ConnectivityService` resolves — reaching for a real site would tell
/// a third party which proxy the user is configuring.
final Uri kDefaultProxyTestTarget = Uri.parse('https://example.com');

/// The Tor Project's check, asked in place of [kDefaultProxyTestTarget] by
/// a route through Tor. It answers whether the request left from a Tor exit
/// and from which address; through Tor it learns only that a Tor client
/// asked.
final Uri kTorCheckTarget = Uri.parse('https://check.torproject.org/api/ip');

/// Where a connection test sends its one request (PROXY-019).
sealed class ProxyTestTarget {
  const ProxyTestTarget();
}

/// A site's own origin: the route the user actually cares about.
final class SiteOrigin extends ProxyTestTarget {
  const SiteOrigin(this.origin);

  final Uri origin;
}

/// No site to ask for: [kDefaultProxyTestTarget], or [kTorCheckTarget]
/// through Tor.
final class NoSite extends ProxyTestTarget {
  const NoSite();
}

/// Where to point the test for a site whose home URL is [siteUrl].
///
/// The site's own origin is the more honest target, but only when the proxy
/// is what carries it: a private or loopback host is exempted from the proxy
/// by PROXY-007, so testing against one would report success without a
/// single byte having traversed the proxy.
ProxyTestTarget proxyTestTarget(String? siteUrl) {
  if (siteUrl == null || siteUrl.isEmpty) return const NoSite();
  final parsed = Uri.tryParse(siteUrl);
  if (parsed == null) return const NoSite();
  if (parsed.scheme != 'http' && parsed.scheme != 'https') {
    return const NoSite();
  }
  if (parsed.host.isEmpty || isPrivateOrLoopbackHost(parsed.host)) {
    return const NoSite();
  }
  // Origin only. `replace` would leave the query and fragment delimiters
  // behind, and the path is the user's business, not the proxy's.
  return SiteOrigin(Uri(
    scheme: parsed.scheme,
    host: parsed.host,
    port: parsed.hasPort ? parsed.port : null,
    path: '/',
  ));
}

/// Runs [probe] with Tor held up, given [within] to come up first.
typedef TorTestHold = Future<ProxyTestResult> Function({
  required Duration within,
  required Future<ProxyTestResult> Function() probe,
});

/// Ask [proxy] to carry one request to [target] and report what happened.
///
/// A site's proxy carries its Tor stream-isolation tag, so a per-site test
/// rides the same circuit the site itself would (PROXY-011). A route that
/// resolves to Tor runs inside [holdTor], so the form's own Tor choice has a
/// runtime even before it is saved; null tests whatever state Tor is in.
/// With no site to ask for, a route through Tor asks [kTorCheckTarget] and
/// reports its verdict.
Future<ProxyTestResult> testProxyConnection(
  OutboundProxy proxy, {
  required ProxyTestTarget target,
  required TorTestHold? holdTor,
  Duration timeout = const Duration(seconds: 15),
}) {
  final effective = proxy.resolved;
  final throughTor = effective.type == ProxyType.TOR;
  final uri = switch (target) {
    SiteOrigin(:final origin) => origin,
    NoSite() => throughTor ? kTorCheckTarget : kDefaultProxyTestTarget,
  };
  Future<ProxyTestResult> probe() =>
      _probe(effective, target: uri, timeout: timeout);
  if (!throughTor || holdTor == null) return probe();
  return holdTor(within: timeout, probe: probe);
}

Future<ProxyTestResult> _probe(
  ProxyRoute effective, {
  required Uri target,
  required Duration timeout,
}) async {
  final client = outboundHttp.clientFor(effective);
  switch (client) {
    case OutboundClientBlocked(:final reason):
      return ProxyTestResult(ProxyTestOutcome.blocked, detail: reason);
    case OutboundClientReady(client: final http.Client probe):
      try {
        final request = http.Request('GET', target)..followRedirects = false;
        final response = await probe.send(request).timeout(timeout);
        final answered = (status: response.statusCode, host: target.host);
        if (response.statusCode == 407) {
          unawaited(response.stream.listen(null).cancel());
          return ProxyTestResult(ProxyTestOutcome.authRejected,
              response: answered);
        }
        if (target == kTorCheckTarget && response.statusCode == 200) {
          final verdict = _torVerdict(await _smallBody(response.stream,
              timeout: timeout));
          if (verdict != null) {
            return ProxyTestResult(
              verdict.isTor
                  ? ProxyTestOutcome.torExit
                  : ProxyTestOutcome.notTorExit,
              response: answered,
              seenFrom: verdict.ip,
            );
          }
        } else {
          // Anywhere else nothing reads the body: a proxy that answered has
          // answered the question. Cancel without awaiting — that future
          // settles only once the transport is torn down, which is what
          // `close()` below does (`IOClient.close` forces open connections
          // shut).
          unawaited(response.stream.listen(null).cancel());
        }
        // The check's own answer is lost (a status of its own, a body it
        // could not be read from), but the route carried a response.
        return ProxyTestResult(ProxyTestOutcome.reachable, response: answered);
      } on TimeoutException {
        return const ProxyTestResult(ProxyTestOutcome.timedOut);
      } on SocksHandshakeFailure catch (e) {
        return _classify(e);
      } on http.ClientException catch (e) {
        return _classify(e);
      } on IOException catch (e) {
        return _classify(e);
      } finally {
        probe.close();
      }
  }
}

/// The Tor check's reply, at most a few KiB of it, or null when it sends
/// more or does not finish in time.
Future<String?> _smallBody(Stream<List<int>> body,
    {required Duration timeout}) async {
  Future<String?> read() async {
    const limit = 4096;
    final bytes = <int>[];
    await for (final chunk in body) {
      bytes.addAll(chunk);
      if (bytes.length > limit) return null;
    }
    return utf8.decode(bytes, allowMalformed: true);
  }

  try {
    return await read().timeout(timeout);
  } on TimeoutException {
    return null;
  }
}

/// What the Tor check answered, read from `{"IsTor": bool, "IP": string}`,
/// or null for anything else.
({bool isTor, String ip})? _torVerdict(String? body) {
  if (body == null) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(body);
  } on FormatException {
    return null;
  }
  return switch (decoded) {
    {'IsTor': final bool isTor, 'IP': final String ip} when ip.isNotEmpty =>
      (isTor: isTor, ip: ip),
    _ => null,
  };
}

/// Sort a transport failure into an outcome without importing `dart:io`.
///
/// This file sits under the settings screens' import closure, so it has to
/// compile for the web target (DESIGN-001) and cannot name `SocketException`
/// or `HandshakeException`. The distinctions that matter to the user survive
/// in the message: dart:io reports a refused CONNECT as
/// "Proxy failed to establish tunnel (407 ...)", and a SOCKS5 proxy that
/// rejects the username/password fails the handshake with an authentication
/// failure.
ProxyTestResult _classify(Exception error) {
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
void logProxyTest(UserProxySettings settings,
    {required ProxyTestResult result}) {
  LogService.instance.log(
    LogTag.proxy,
    message: 'Connection test: ${settings.describeForLogs()} '
        'outcome=${result.outcome.name} '
        'status=${result.response?.status ?? '-'}',
    level: switch (result.outcome) {
      ProxyTestOutcome.reachable || ProxyTestOutcome.torExit => LogLevel.info,
      ProxyTestOutcome.notTorExit ||
      ProxyTestOutcome.authRejected ||
      ProxyTestOutcome.unreachable ||
      ProxyTestOutcome.timedOut ||
      ProxyTestOutcome.blocked =>
        LogLevel.error,
    },
    sensitivity: LogSensitivity.sensitive,
  );
}
