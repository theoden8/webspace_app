// A tor started outside the app (Orbot, the system tor service, Tor
// Browser's), reached over its SOCKS port. The engine treats it like the
// embedded runtime: the same per-site SOCKS credentials, which a tor with
// IsolateSOCKSAuth (its default) turns into per-site circuits. What it
// cannot do is anything that needs tor's control port. Spec: TOR-025.
//
// Free of dart:io, like tor_service.dart; the socket probe lives in
// tor_socks_probe_io.dart.

import 'dart:async';

import 'package:webspace/services/log_service.dart';
import 'package:webspace/services/outbound_http_types.dart'
    show splitProxyAddress;
import 'package:webspace/services/tor_engine.dart';

/// What a listener said when asked whether it is tor.
enum ExternalTorAnswer {
  /// It answered an HTTP request with tor's own "Tor is not an HTTP Proxy",
  /// which C tor and Arti both send from a SOCKS port.
  tor,

  /// Something answered, and not as tor.
  notTor,

  /// Nothing accepted the connection.
  unreachable,
}

typedef ExternalTorIdentify = Future<ExternalTorAnswer> Function(
    String host, {required int port});

class ExternalTorRuntime implements TorRuntime {
  ExternalTorRuntime({
    required String Function() address,
    required ExternalTorIdentify identify,
  })  : _address = address,
        _identify = identify;

  final String Function() _address;
  final ExternalTorIdentify _identify;
  final StreamController<TorStatus> _events =
      StreamController<TorStatus>.broadcast();

  /// Bumped per [_connect], so an answer for an address the user has since
  /// changed cannot overwrite the answer for the new one.
  int _attempt = 0;

  @override
  bool get isAvailable => true;

  @override
  Stream<TorStatus> get events => _events.stream;

  @override
  Future<void> start() => _connect();

  /// Asked again after the address changes, or when the engine finds the
  /// listener gone after the app was away.
  Future<void> reconnect() => _connect();

  @override
  Future<void> reopenListeners() => _connect();

  @override
  Future<void> stop() async {
    _attempt++;
    _events.add(const TorStopped());
  }

  /// No control port, so no NEWNYM. The status card offers no button for it.
  @override
  Future<void> rebuildCircuits() async {}

  @override
  Future<void> applyExitCountry(String? exitNodes, {String? geoipFile}) async {
    if (exitNodes == null) return;
    throw const TorExitPinUnsupported(
        'An exit country needs the built-in Tor. The external tor chooses its '
        'own exits, and this app has no control port to change them.');
  }

  /// Bridges are the external tor's own configuration.
  @override
  Future<int> startTransport(String transport) async => 0;

  @override
  Future<void> setTorrcOptions(List<(String, String)> options) async {}

  Future<void> _connect() async {
    final attempt = ++_attempt;
    final address = _address();
    final parsed = splitProxyAddress(address);
    if (parsed == null) {
      _fail('The external Tor address "$address" is not host:port.');
      return;
    }
    LogTag.tor.debug('Asking $address whether it is tor', sensitive: true);
    final answer = await _identify(parsed.host, port: parsed.port);
    if (attempt != _attempt) return;
    switch (answer) {
      case ExternalTorAnswer.tor:
        LogTag.tor.debug('$address answered as tor', sensitive: true);
        _events.add(TorUp(parsed.host, port: parsed.port));
      case ExternalTorAnswer.notTor:
        _fail('Something answers at $address, but not as tor.');
      case ExternalTorAnswer.unreachable:
        _fail('Nothing answers at $address.');
    }
  }

  void _fail(String message) {
    _events.add(TorErrored(message,
        failure: TorFailure(
            kind: TorFailureKind.externalUnreachable, detail: message)));
  }
}

