import 'package:flutter/foundation.dart';

import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/utils/concurrency.dart';

/// What the connection indicator shows for a proxy (PROXY-031).
enum ProxyHealthState { checking, reachable, authRejected, unreachable }

class ProxyHealth {
  const ProxyHealth(this.state, {this.checkedAt, this.detail});

  final ProxyHealthState state;

  /// When the answer came back; null while [ProxyHealthState.checking].
  final DateTime? checkedAt;

  /// The underlying error, verbatim, for the log and the tooltip.
  final String? detail;
}

typedef ProxyProbe = Future<ProxyTestResult> Function(
    UserProxySettings settings);

/// Remembers whether each proxy answered when last asked, and asks again
/// when an indicator shows a stale answer.
///
/// Probes only when something on screen wants the answer, never on a timer:
/// a background probe would be traffic the user did not cause. Keyed by the
/// proxy's configuration rather than by where it came from, so every surface
/// showing the same proxy shows the same answer, and an edit starts afresh.
class ProxyHealthService extends ChangeNotifier {
  ProxyHealthService({ProxyProbe? probe, DateTime Function()? now})
      : _probe = probe ?? _defaultProbe,
        _now = now ?? DateTime.now;

  static ProxyHealthService instance = ProxyHealthService();

  /// How long an answer stands before an indicator asks again.
  static const Duration freshFor = Duration(minutes: 2);

  final ProxyProbe _probe;
  final DateTime Function() _now;
  final Map<_ProxyKey, ProxyHealth> _results = {};
  final SingleFlight<_ProxyKey, ProxyHealth> _probes = SingleFlight();

  static Future<ProxyTestResult> _defaultProbe(UserProxySettings settings) =>
      testProxyConnection(settings, target: kDefaultProxyTestTarget);

  /// Whether [settings] names a route the indicator can probe: a concrete
  /// proxy, or Tor. DEFAULT is the absence of one, and an unresolved SAVED
  /// has nowhere to send a probe.
  static bool probeable(UserProxySettings settings) =>
      settings.type != ProxyType.DEFAULT && settings.type != ProxyType.SAVED;

  ProxyHealth? statusOf(UserProxySettings settings) {
    final key = _keyOf(settings);
    if (_probes.isRunning(key)) {
      return const ProxyHealth(ProxyHealthState.checking);
    }
    return _results[key];
  }

  bool isFresh(UserProxySettings settings) {
    final checkedAt = _results[_keyOf(settings)]?.checkedAt;
    return checkedAt != null && _now().difference(checkedAt) < freshFor;
  }

  /// Probe [settings], or return the answer already known when it is fresh
  /// and [force] is false. Concurrent calls for one proxy share a probe.
  ///
  /// [settings] must be resolved (`resolveEffectiveProxy`): the probe goes
  /// where they point, and an unresolved DEFAULT would test the app-wide
  /// proxy instead.
  Future<ProxyHealth> check(UserProxySettings settings, {bool force = false}) {
    final key = _keyOf(settings);
    final starting = !_probes.isRunning(key);
    if (starting && !force && isFresh(settings)) {
      return Future.value(_results[key]!);
    }
    final probe = _probes.run(key, () => _probeHealth(settings));
    if (starting) {
      notifyListeners();
      probe.then((health) {
        _results[key] = health;
        notifyListeners();
      });
    }
    return probe;
  }

  Future<ProxyHealth> _probeHealth(UserProxySettings settings) async {
    try {
      final result = await _probe(settings);
      logProxyTest(settings, result);
      return ProxyHealth(
        switch (result.outcome) {
          ProxyTestOutcome.reachable => ProxyHealthState.reachable,
          ProxyTestOutcome.authRejected => ProxyHealthState.authRejected,
          ProxyTestOutcome.unreachable ||
          ProxyTestOutcome.timedOut ||
          ProxyTestOutcome.blocked =>
            ProxyHealthState.unreachable,
        },
        checkedAt: _now(),
        detail: result.detail,
      );
    } on Exception catch (e) {
      return ProxyHealth(
        ProxyHealthState.unreachable,
        checkedAt: _now(),
        detail: '$e',
      );
    }
  }
}

/// A proxy's identity for caching. The password is part of it, so fixing a
/// rejected password is not answered from the rejection.
typedef _ProxyKey = (ProxyType, String?, String?, String?);

_ProxyKey _keyOf(UserProxySettings s) =>
    (s.type, s.address, s.username, s.password);
