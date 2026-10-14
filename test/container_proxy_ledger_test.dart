import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/container_names.dart';
import 'package:webspace/services/container_proxy_ledger.dart';
import 'package:webspace/services/proxy_refused.dart';

/// Models the fork's container proxy table (privacy-v12): a build naming a
/// proxy writes the container's entry, a build naming none leaves it, and
/// only a clear by container id removes it.
class _ForkProxyTable {
  final Map<ContainerName, Object> proxies = {};
  final List<ContainerName> clears = [];

  void build(ContainerName containerId, {required Object? proxy}) {
    if (proxy != null) proxies[containerId] = proxy;
  }

  Future<void> clear(ContainerName containerId) async {
    clears.add(containerId);
    proxies.remove(containerId);
  }
}

final _a = ContainerName.of(ContainerKey.named('a'));
final _b = ContainerName.of(ContainerKey.named('b'));

void main() {
  const proxy = 'socks5://proxy:1080';

  bool mustRelease(
    ContainerProxyLedger ledger, {
    bool bindsProxyPerSite = true,
    ContainerName? containerId,
    bool noContainer = false,
    bool siteNamesProxy = true,
    bool boundProxy = false,
    bool proxyUnavailable = false,
  }) =>
      ledger.mustRelease(
        bindsProxyPerSite: bindsProxyPerSite,
        containerId: noContainer ? null : containerId ?? _a,
        siteNamesProxy: siteNamesProxy,
        boundProxy: boundProxy,
        proxyUnavailable: proxyUnavailable,
      );

  group('PROXY-029: a site moved off its proxy stops using it', () {
    test('proxy then DEFAULT: the rebuild clears the container first', () async {
      final ledger = ContainerProxyLedger();
      final fork = _ForkProxyTable();

      ledger.noteBuild(_a, proxy: proxy);
      fork.build(_a, proxy: proxy);

      // The site is now DEFAULT: the rebuild names no proxy.
      expect(mustRelease(ledger), isTrue);
      await ledger.release(_a, clear: fork.clear);
      fork.build(_a, proxy: null);

      expect(fork.proxies, isEmpty);
      expect(ledger.holds(_a), isFalse);
      expect(mustRelease(ledger), isFalse,
          reason: 'the next DEFAULT build has nothing left to clear');
    });

    test('without the clear the fork keeps the old proxy', () {
      final fork = _ForkProxyTable();
      fork.build(_a, proxy: proxy);
      fork.build(_a, proxy: null);
      expect(fork.proxies[_a], proxy,
          reason: 'what the ledger exists to undo');
    });

    test('a container never given a proxy is not cleared', () {
      final ledger = ContainerProxyLedger();
      ledger.noteBuild(_a, proxy: null);
      expect(mustRelease(ledger), isFalse);
    });

    test('a build that carries a proxy replaces the old one itself', () {
      final ledger = ContainerProxyLedger()..noteBuild(_a, proxy: proxy);
      expect(mustRelease(ledger, boundProxy: true), isFalse);
    });

    test('an unavailable proxy keeps the old one: the page stays blank', () {
      final ledger = ContainerProxyLedger()..noteBuild(_a, proxy: proxy);
      expect(mustRelease(ledger, proxyUnavailable: true), isFalse);
    });

    test('a caller that states no proxy leaves the container alone', () {
      final ledger = ContainerProxyLedger()..noteBuild(_a, proxy: proxy);
      expect(mustRelease(ledger, siteNamesProxy: false), isFalse);
    });

    test('no container, or a process-wide binding, has nothing to clear', () {
      final ledger = ContainerProxyLedger()..noteBuild(_a, proxy: proxy);
      expect(mustRelease(ledger, noContainer: true), isFalse);
      expect(mustRelease(ledger, bindsProxyPerSite: false), isFalse);
    });

    test('only the named container is cleared', () async {
      final ledger = ContainerProxyLedger()
        ..noteBuild(_a, proxy: proxy)
        ..noteBuild(_b, proxy: proxy);
      final fork = _ForkProxyTable()
        ..build(_a, proxy: proxy)
        ..build(_b, proxy: proxy);
      await ledger.release(_a, clear: fork.clear);
      expect(fork.clears, [_a]);
      expect(fork.proxies.keys, [_b]);
      expect(ledger.holds(_b), isTrue);
    });

    test('a failed clear is asked for again on the next build', () async {
      final ledger = ContainerProxyLedger()..noteBuild(_a, proxy: proxy);
      await expectLater(
        ledger.release(_a,
            clear: (_) async => throw const ProxyRefused('channel')),
        throwsA(isA<ProxyRefused>()),
      );
      expect(ledger.holds(_a), isTrue);
      expect(mustRelease(ledger), isTrue);
    });

    test('a proxy written while the clear is in flight stays tracked', () async {
      final ledger = ContainerProxyLedger()..noteBuild(_a, proxy: proxy);
      final gate = Completer<void>();
      final release = ledger.release(_a, clear: (_) => gate.future);
      ledger.noteBuild(_a, proxy: proxy);
      gate.complete();
      await release;
      expect(ledger.holds(_a), isTrue,
          reason: 'forgetting it would let a later DEFAULT build keep it');
    });
  });
}
