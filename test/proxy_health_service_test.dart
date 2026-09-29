import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_health_service.dart';
import 'package:webspace/services/proxy_test_service.dart';
import 'package:webspace/settings/proxy.dart';

UserProxySettings _socks([String password = 'p']) => UserProxySettings(
      type: ProxyType.SOCKS5,
      address: '10.8.0.1:1080',
      username: 'u',
      password: password,
    );

void main() {
  test('each probe outcome maps to what the indicator shows (PROXY-030)',
      () async {
    const cases = {
      ProxyTestOutcome.reachable: ProxyHealthState.reachable,
      ProxyTestOutcome.authRejected: ProxyHealthState.authRejected,
      ProxyTestOutcome.unreachable: ProxyHealthState.unreachable,
      ProxyTestOutcome.timedOut: ProxyHealthState.unreachable,
      ProxyTestOutcome.blocked: ProxyHealthState.unreachable,
    };
    for (final entry in cases.entries) {
      final service = ProxyHealthService(
          probe: (_) async => ProxyTestResult(entry.key));
      final health = await service.check(_socks());
      expect(health.state, entry.value, reason: '${entry.key}');
    }
  });

  test('concurrent checks of one proxy share a probe', () async {
    var probes = 0;
    final gate = Completer<ProxyTestResult>();
    final service = ProxyHealthService(probe: (_) {
      probes++;
      return gate.future;
    });
    final a = service.check(_socks());
    final b = service.check(_socks());
    expect(service.statusOf(_socks())!.state, ProxyHealthState.checking);
    gate.complete(const ProxyTestResult(ProxyTestOutcome.reachable));
    await Future.wait([a, b]);
    expect(probes, 1);
  });

  test('a fresh answer is reused, a stale one is asked again', () async {
    var probes = 0;
    var now = DateTime(2026, 9, 29, 12);
    final service = ProxyHealthService(
      probe: (_) async {
        probes++;
        return const ProxyTestResult(ProxyTestOutcome.reachable);
      },
      now: () => now,
    );
    await service.check(_socks());
    await service.check(_socks());
    expect(probes, 1);
    now = now.add(ProxyHealthService.freshFor);
    expect(service.isFresh(_socks()), isFalse);
    await service.check(_socks());
    expect(probes, 2);
  });

  test('force asks again even when fresh', () async {
    var probes = 0;
    final service = ProxyHealthService(probe: (_) async {
      probes++;
      return const ProxyTestResult(ProxyTestOutcome.reachable);
    });
    await service.check(_socks());
    await service.check(_socks(), force: true);
    expect(probes, 2);
  });

  test('a new password is not answered from the old rejection', () async {
    final service = ProxyHealthService(
      probe: (s) async => ProxyTestResult(s.password == 'right'
          ? ProxyTestOutcome.reachable
          : ProxyTestOutcome.authRejected),
    );
    await service.check(_socks('wrong'));
    expect(service.statusOf(_socks('right')), isNull);
    final health = await service.check(_socks('right'));
    expect(health.state, ProxyHealthState.reachable);
  });

  test('a probe that throws reads as unreachable, with the error', () async {
    final service = ProxyHealthService(probe: (_) => throw StateError('boom'));
    final health = await service.check(_socks());
    expect(health.state, ProxyHealthState.unreachable);
    expect(health.detail, contains('boom'));
  });

  test('DEFAULT and an unresolved saved proxy are never probed', () {
    expect(
        ProxyHealthService.probeable(UserProxySettings(type: ProxyType.DEFAULT)),
        isFalse);
    expect(
        ProxyHealthService.probeable(
            UserProxySettings(type: ProxyType.SAVED, savedProxyId: 'x')),
        isFalse);
    expect(ProxyHealthService.probeable(_socks()), isTrue);
  });
}
