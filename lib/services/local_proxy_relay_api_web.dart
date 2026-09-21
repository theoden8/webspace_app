import 'package:webspace/services/proxy_relay.dart';

/// Web twin of the in-process relay adapter (DESIGN-001).
///
/// [`LocalProxyRelay`] is a `ServerSocket`, so the real adapter reaches
/// `dart:io` and every UI file that transitively imports
/// `ProxyRouterService` would stop compiling for web -- which is how the
/// design gallery loses a screen.
///
/// Router mode cannot run here anyway: the gate gives it to Android and
/// Apple only. Refusing to bind is the fail-closed answer, and it is the
/// same one the caller already handles, since a relay that cannot bind
/// puts the app back on PROXY-008.
class LocalProxyRelayApi implements ProxyRelayApi {
  LocalProxyRelayApi();

  @override
  String? lastError = 'there is no local relay on this platform';

  @override
  Future<({String host, int port})?> startRouter(String realm) async => null;

  @override
  Future<bool> setRoutes(Map<String, Map<String, Object?>> routes) async =>
      false;

  @override
  Future<Map<String, String>> probeResults() async => const {};

  @override
  Future<void> clearProbeResults() async {}

  @override
  Future<void> stop() async {}
}
