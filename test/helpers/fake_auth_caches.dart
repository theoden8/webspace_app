import 'dart:async';

import 'package:webspace/services/proxy_router_engine.dart';

/// Chromium's proxy auth caches as a device keeps them, behind the
/// attribution probe (PROXY-015).
///
/// Each profile has a cache of its own unless [profileOf] maps two
/// identities to one, which is the device the check exists for. A probe
/// sends the credential its profile has cached when it starts; with none it
/// is challenged and answers with its own, which the profile caches once
/// the load ends. So two probes of one shared cache that run side by side
/// both answer with their own, and only a probe that starts after the
/// other's ended carries the other's credential.
class FakeAuthCaches {
  FakeAuthCaches({
    required this.record,
    String Function(RouterIdentity identity)? profileOf,
  }) : profileOf = profileOf ?? ((identity) => identity);

  /// One cache for every profile.
  FakeAuthCaches.shared({required this.record})
    : profileOf = ((_) => 'the one session');

  /// Where the relay notes nonce -> the identity whose credential it saw.
  final void Function({required String nonce, required String identity}) record;
  final String Function(RouterIdentity identity) profileOf;

  final _caches = <String, RouterIdentity>{};

  /// Probes by identity, in the order they started.
  final started = <RouterIdentity>[];

  /// The most probes that were in flight at once.
  var mostAtOnce = 0;
  var _inFlight = 0;

  /// Identities whose probe reaches the relay with nothing at all, and how
  /// many times it does so before it gets through.
  final silent = <RouterIdentity, int>{};

  /// A probe of an identity named here waits for its completer.
  final gates = <RouterIdentity, Completer<void>>{};

  Future<void> probe(RouterIdentity identity, {required String url}) async {
    started.add(identity);
    _inFlight++;
    if (_inFlight > mostAtOnce) mostAtOnce = _inFlight;
    try {
      final cached = _caches[profileOf(identity)];
      await Future<void>.delayed(Duration.zero);
      await gates[identity]?.future;
      final left = silent[identity] ?? 0;
      if (left > 0) {
        silent[identity] = left - 1;
        return;
      }
      final presented = cached ?? identity;
      record(nonce: nonceOf(url), identity: presented);
      _caches[profileOf(identity)] ??= presented;
    } finally {
      _inFlight--;
    }
  }

  /// The nonce a probe URL carries, as the relay reads it off the host.
  static String nonceOf(String url) =>
      Uri.parse(url).host.replaceAll(ProxyRouterEngine.probeSuffix, '');
}
