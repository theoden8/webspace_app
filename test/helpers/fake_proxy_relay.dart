import 'package:webspace/services/proxy_relay.dart';
import 'package:webspace/services/proxy_router_service.dart';

/// The relay behind the per-site proxy router (PROXY-013), modelling its
/// wire contract rather than stubbing it away: an unknown credential is a
/// route the relay does not have, which is what makes revocation and
/// fail-closed assertions mean anything.
class FakeRelay implements ProxyRelayApi {
  Map<String, Map<String, Object?>> installed = {};
  String? startedRealm;
  int startCalls = 0;
  int stopCalls = 0;

  /// When false, `startRouter` reports a bind failure.
  bool canBind = true;

  @override
  String? get lastError => canBind ? null : 'FAKE_BIND_FAILED: no';

  /// When false, `setRoutes` rejects the table.
  bool acceptsRoutes = true;

  /// The address the fake reports binding. A random 127/8 one, as the
  /// real relay picks, so nothing can quietly assume 127.0.0.1.
  static const String boundHost = '127.63.9.212';

  /// When set, `startRouter` answers once it completes.
  Future<void>? bindsAfter;

  /// The port the next bind lands on; a fresh listener gets a fresh one.
  int nextPort = 43210;

  /// False once the listener stops answering, as a relay whose socket was
  /// closed under it, or whose accept is wedged, stops (PROXY-032). A bind
  /// makes a new listener, which answers.
  bool serves = true;
  int servingCalls = 0;

  @override
  Future<({String host, int port})?> startRouter(String realm) async {
    startCalls++;
    await bindsAfter;
    if (!canBind) return null;
    startedRealm = realm;
    serves = true;
    return (host: boundHost, port: nextPort);
  }

  @override
  Future<bool> serving() async {
    servingCalls++;
    return serves && startedRealm != null;
  }

  @override
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes) async {
    if (!acceptsRoutes) return false;
    installed = routes;
    return true;
  }

  /// nonce -> siteId, as the relay would have observed it.
  Map<String, String> probes = {};
  int clearProbeCalls = 0;

  @override
  Future<Map<String, String>> probeResults() async => probes;

  @override
  Future<void> clearProbeResults() async {
    clearProbeCalls++;
    probes = {};
  }

  @override
  Future<void> stop() async {
    stopCalls++;
    installed = {};
    startedRealm = null;
    probes = {};
  }

  /// The upstream the relay would pick for [credential], or null when the
  /// connection would be answered 502.
  Map<String, Object?>? resolve(String credential) => installed[credential];
}

/// The process-wide rule as a start drives it: [binds] answers each point at
/// the relay, and every step lands in [steps].
class FakeOverride implements ProxyRouterOverride {
  FakeOverride({this.binds = true});

  final bool binds;
  final steps = <String>[];

  @override
  Future<bool> bind(String host, {required int port}) async {
    steps.add('bind $host:$port');
    return binds;
  }

  @override
  Future<void> clear() async => steps.add('clear');
}
