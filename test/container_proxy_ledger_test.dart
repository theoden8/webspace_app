import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_proxy_ledger.dart';

/// Models the fork's container proxy table (privacy-v12): a build naming a
/// proxy writes the container's entry, a build naming none leaves it, and
/// only a clear by container id removes it.
class _ForkProxyTable {
  final Map<String, Object> proxies = {};
  final List<String> clears = [];

  void build(String containerId, Object? proxy) {
    if (proxy != null) proxies[containerId] = proxy;
  }

  Future<void> clear(String containerId) async {
    clears.add(containerId);
    proxies.remove(containerId);
  }
}

void main() {
  const proxy = 'socks5://proxy:1080';

  bool mustRelease(
    ContainerProxyLedger ledger, {
    bool bindsProxyPerSite = true,
    String? containerId = 'ws-a',
    bool siteNamesProxy = true,
    bool boundProxy = false,
    bool proxyUnavailable = false,
  }) =>
      ledger.mustRelease(
        bindsProxyPerSite: bindsProxyPerSite,
        containerId: containerId,
        siteNamesProxy: siteNamesProxy,
        boundProxy: boundProxy,
        proxyUnavailable: proxyUnavailable,
      );

  group('PROXY-029: a site moved off its proxy stops using it', () {
    test('proxy then DEFAULT: the rebuild clears the container first', () async {
      final ledger = ContainerProxyLedger();
      final fork = _ForkProxyTable();

      ledger.noteBuild('ws-a', proxy);
      fork.build('ws-a', proxy);

      // The site is now DEFAULT: the rebuild names no proxy.
      expect(mustRelease(ledger), isTrue);
      await ledger.release('ws-a', fork.clear);
      fork.build('ws-a', null);

      expect(fork.proxies, isEmpty);
      expect(ledger.holds('ws-a'), isFalse);
      expect(mustRelease(ledger), isFalse,
          reason: 'the next DEFAULT build has nothing left to clear');
    });

    test('without the clear the fork keeps the old proxy', () {
      final fork = _ForkProxyTable();
      fork.build('ws-a', proxy);
      fork.build('ws-a', null);
      expect(fork.proxies['ws-a'], proxy,
          reason: 'what the ledger exists to undo');
    });

    test('a container never given a proxy is not cleared', () {
      final ledger = ContainerProxyLedger();
      ledger.noteBuild('ws-a', null);
      expect(mustRelease(ledger), isFalse);
    });

    test('a build that carries a proxy replaces the old one itself', () {
      final ledger = ContainerProxyLedger()..noteBuild('ws-a', proxy);
      expect(mustRelease(ledger, boundProxy: true), isFalse);
    });

    test('an unavailable proxy keeps the old one: the page stays blank', () {
      final ledger = ContainerProxyLedger()..noteBuild('ws-a', proxy);
      expect(mustRelease(ledger, proxyUnavailable: true), isFalse);
    });

    test('a caller that states no proxy leaves the container alone', () {
      final ledger = ContainerProxyLedger()..noteBuild('ws-a', proxy);
      expect(mustRelease(ledger, siteNamesProxy: false), isFalse);
    });

    test('no container, or a process-wide binding, has nothing to clear', () {
      final ledger = ContainerProxyLedger()..noteBuild('ws-a', proxy);
      expect(mustRelease(ledger, containerId: null), isFalse);
      expect(mustRelease(ledger, bindsProxyPerSite: false), isFalse);
    });

    test('only the named container is cleared', () async {
      final ledger = ContainerProxyLedger()
        ..noteBuild('ws-a', proxy)
        ..noteBuild('ws-b', proxy);
      final fork = _ForkProxyTable()
        ..build('ws-a', proxy)
        ..build('ws-b', proxy);
      await ledger.release('ws-a', fork.clear);
      expect(fork.clears, ['ws-a']);
      expect(fork.proxies.keys, ['ws-b']);
      expect(ledger.holds('ws-b'), isTrue);
    });

    test('a failed clear is asked for again on the next build', () async {
      final ledger = ContainerProxyLedger()..noteBuild('ws-a', proxy);
      await expectLater(
        ledger.release('ws-a', (_) async => throw Exception('channel')),
        throwsException,
      );
      expect(ledger.holds('ws-a'), isTrue);
      expect(mustRelease(ledger), isTrue);
    });

    test('a proxy written while the clear is in flight stays tracked', () async {
      final ledger = ContainerProxyLedger()..noteBuild('ws-a', proxy);
      final gate = Completer<void>();
      final release = ledger.release('ws-a', (_) => gate.future);
      ledger.noteBuild('ws-a', proxy);
      gate.complete();
      await release;
      expect(ledger.holds('ws-a'), isTrue,
          reason: 'forgetting it would let a later DEFAULT build keep it');
    });
  });
}
