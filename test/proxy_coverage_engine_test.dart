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

    test('a per-store proxy covers the mounting navigation and nothing after',
        () {
      expect(
        ProxyCoverageEngine.coverageFor(
          binding: ProxyBinding.perSite,
          proxyConfigured: true,
          isMountNavigation: true,
        ),
        ProxyCoverage.established,
      );
      expect(
        ProxyCoverageEngine.coverageFor(
          binding: ProxyBinding.perSite,
          proxyConfigured: true,
          isMountNavigation: false,
        ),
        ProxyCoverage.unprovable,
        reason: 'BUG-014 attempts 90 and 91: the store carries the proxy for '
            'the navigation that mounted the view and for no other',
      );
    });
  });

  group('ProxyCoverageGate', () {
    ProxyCoverageGate gate(ProxyBinding binding, {String mount = 'https://a/'}) =>
        ProxyCoverageGate(
          binding: binding,
          proxyConfigured: true,
          mountUrl: mount,
        );

    test('the mount slot goes to the URL the view was built on', () {
      final g = gate(ProxyBinding.perSite);
      expect(g.evaluate('https://a/'), ProxyCoverage.established);
      expect(g.evaluate('https://a/next'), ProxyCoverage.unprovable);
    });

    test('the slot is spent even when the first navigation is not the mount '
        'one', () {
      // Fail-closed: a platform that does not report the mounting navigation
      // through this seam must not hand the slot to whatever the page
      // navigated to first, and must not hand it to a later return to the
      // entry URL either -- by then the view is long since mounted.
      final g = gate(ProxyBinding.perSite);
      expect(g.evaluate('https://a/elsewhere'), ProxyCoverage.unprovable);
      expect(g.evaluate('https://a/'), ProxyCoverage.unprovable);
    });

    test('a fresh gate is what reopening a blocked destination buys', () {
      final blocked = 'https://a/next';
      final spent = gate(ProxyBinding.perSite);
      spent.evaluate('https://a/');
      expect(spent.evaluate(blocked), ProxyCoverage.unprovable);
      // The remount builds the view on the destination itself.
      final remounted = gate(ProxyBinding.perSite, mount: blocked);
      expect(remounted.evaluate(blocked), ProxyCoverage.established);
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
