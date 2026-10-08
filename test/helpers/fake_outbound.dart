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
  final List<http.Request> requests = [];

  UserProxySettings? get lastQuery => queries.isEmpty ? null : queries.last;
  List<Uri> get requested => [for (final r in requests) r.url];
  set block(bool value) => blockWhen = (_) => value;

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    queries.add(settings);
    if (blockWhen(settings)) return OutboundClientBlocked(blockReason);
    return OutboundClientReady(client?.call() ??
        MockClient((req) async {
          requests.add(req);
          return responder(req);
        }));
  }
}
