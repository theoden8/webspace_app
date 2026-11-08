import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// [OutboundHttpFactory] that records every proxy it is asked for and every
/// request it serves. Answers with [responder], or hands out [client] when a
/// test needs its own transport; refuses where [blockWhen] says.
class FakeOutbound implements OutboundHttpFactory {
  FakeOutbound({
    FutureOr<http.Response> Function(http.Request request)? responder,
    this.client,
    bool Function(UserProxySettings settings)? blockWhen,
    this.blockReason = 'blocked by test fake',
  })  : responder = responder ?? ((_) => http.Response('', 200)),
        blockWhen = blockWhen ?? ((_) => false);

  FutureOr<http.Response> Function(http.Request request) responder;
  final http.Client Function()? client;
  bool Function(UserProxySettings settings) blockWhen;
  final String blockReason;

  final List<UserProxySettings> queries = [];
  final List<BodyEncoding> encodings = [];
  final List<http.Request> requests = [];

  /// The `allowPrivateHost` each [pageSteeredClientFor] call was given, in order,
  /// so a test can assert which document host a page-linked fetch permits.
  final List<String?> allowPrivateHosts = [];

  UserProxySettings? get lastQuery => queries.isEmpty ? null : queries.last;
  List<Uri> get requested => [for (final r in requests) r.url];
  set block(bool value) => blockWhen = (_) => value;

  @override
  OutboundClient clientFor(
    ProxyRoute route, {
    BodyEncoding encoding = BodyEncoding.decoded,
  }) {
    queries.add(route);
    encodings.add(encoding);
    if (blockWhen(route)) return OutboundClientBlocked(blockReason);
    return OutboundClientReady(client?.call() ??
        MockClient((req) async {
          requests.add(req);
          return responder(req);
        }));
  }

  /// The fake serves the same transport for a page-steered fetch; the real
  /// resolve-and-pin judgement lives in the dart:io factory and is exercised by
  /// the connection-layer test (SEC-049), not through this fake. The requested
  /// [allowPrivateHost] is recorded for assertions.
  @override
  OutboundClient pageSteeredClientFor(ProxyRoute route,
      {String? allowPrivateHost}) {
    allowPrivateHosts.add(allowPrivateHost);
    return clientFor(route);
  }
}
