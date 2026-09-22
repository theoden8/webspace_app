// Whether a navigation a proxied site is about to make can be shown to go
// through that proxy (LEAK-010).
//
// Asserted on the pure decision rather than on a live WebView, for the reason
// PROXY-027 gives: this suite runs on Linux, where a platform read answers
// "not Apple" first and every further assertion passes without meaning it.

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';

void main() {
  group('ProxyCoverageEngine', () {
    test('a site with no proxy claims nothing, so nothing is unprovable', () {
      for (final binding in ProxyBinding.values) {
        for (final isMount in [true, false]) {
          expect(
            ProxyCoverageEngine.coverageFor(
              binding: binding,
              proxyConfigured: false,
              isMountNavigation: isMount,
            ),
            ProxyCoverage.notClaimed,
            reason: 'binding=$binding isMount=$isMount',
          );
        }
      }
    });

    test('a process-wide rule covers every navigation alike', () {
      for (final isMount in [true, false]) {
        expect(
          ProxyCoverageEngine.coverageFor(
            binding: ProxyBinding.processWide,
            proxyConfigured: true,
            isMountNavigation: isMount,
          ),
          ProxyCoverage.established,
          reason: 'isMount=$isMount',
        );
      }
    });

    test('a per-store proxy covers every navigation on that store', () {
      for (final mounting in [true, false]) {
        expect(
          ProxyCoverageEngine.coverageFor(
            binding: ProxyBinding.perSite,
            proxyConfigured: true,
            isMountNavigation: mounting,
          ),
          ProxyCoverage.established,
          reason: 'BUG-014 attempt 102 measured a store carrying its proxy on '
              'every navigation, at any distance from the first frame and on '
              'a second navigation to a different origin. The readings that '
              'said otherwise pointed their origins at an address of the test '
              'machine, which is loopback-routed and never proxied. '
              'isMountNavigation=$mounting',
        );
      }
    });
  });

  group('ProxyCoverageGate', () {
    ProxyCoverageGate gate(ProxyBinding binding, {String mount = 'https://a/'}) =>
        ProxyCoverageGate(
          binding: binding,
          proxyConfigured: true,
          mountUrl: mount,
        );

    test('a proxied site is covered on the mount navigation and after it', () {
      // The gate used to spend a one-shot slot on the mounting URL and call
      // everything after it unprovable, which cancelled the navigations a
      // user actually makes. BUG-014 attempt 102 measured the store carrying
      // its proxy throughout, so nothing here is blocked any more.
      final g = gate(ProxyBinding.perSite);
      expect(g.evaluate('https://a/'), ProxyCoverage.established);
      expect(g.evaluate('https://a/next'), ProxyCoverage.established);
      expect(g.evaluate('https://b/elsewhere'), ProxyCoverage.established);
    });

    test('nothing is ever blocked under a process-wide rule', () {
      final g = gate(ProxyBinding.processWide);
      expect(g.evaluate('https://a/'), ProxyCoverage.established);
      expect(g.evaluate('https://b/deep/link'), ProxyCoverage.established);
    });

    test('a DEFAULT site is unaffected on every binding', () {
      for (final binding in ProxyBinding.values) {
        final g = ProxyCoverageGate(
          binding: binding,
          proxyConfigured: false,
          mountUrl: 'https://a/',
        );
        expect(g.evaluate('https://a/'), ProxyCoverage.notClaimed);
        expect(g.evaluate('https://b/'), ProxyCoverage.notClaimed);
      }
    });
  });
}
