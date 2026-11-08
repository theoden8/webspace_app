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

  // No pageSteeredClientFor: a page-steered fetch reaches this fake through
  // `buildPageSteeredClient`, which routes a non-default factory to [clientFor]
  // above (so the fake captures the fetch). The real resolve-and-pin judgement
  // lives in the dart:io factory and is exercised by the connection-layer test
  // (SEC-049), not through this fake.
}
