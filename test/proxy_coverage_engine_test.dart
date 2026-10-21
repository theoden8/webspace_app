// Whether a navigation a site is about to make can be shown to go through
// the route it needs (LEAK-010, LEAK-016).
//
// Asserted on the pure decision rather than on a live WebView, for the reason
// PROXY-027 gives: this suite runs on Linux, where a platform read answers
// "not Apple" first and every further assertion passes without meaning it.

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/proxy_coverage_engine.dart';
import 'package:webspace/services/url_host.dart';

const _onion = 'duckduckgogg42xjoc72x3sjasowoarfbgcmvfimaftt6twagswzczad.onion';

void main() {
  group('ProxyCoverageEngine', () {
    test('a site with no proxy claims nothing, so nothing is unprovable', () {
      for (final binding in ProxyBinding.values) {
        for (final isMount in [true, false]) {
          expect(
            ProxyCoverageEngine.coverageFor(
              binding: binding,
              proxyConfigured: false,
              destination: Host('example.com'),
              isMountNavigation: isMount,
            ),
            const NotClaimed(),
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
            destination: Host('example.com'),
            isMountNavigation: isMount,
          ),
          const Established(),
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
            destination: Host('example.com'),
            isMountNavigation: mounting,
          ),
          const Established(),
          reason: 'BUG-014 measured a store carrying its proxy on '
              'every navigation, at any distance from the first frame and on '
              'a second navigation to a different origin. The readings that '
              'said otherwise pointed their origins at an address of the test '
              'machine, which is loopback-routed and never proxied. '
              'isMountNavigation=$mounting',
        );
      }
    });

    test('LEAK-016: an onion service needs a proxy on every binding', () {
      for (final binding in ProxyBinding.values) {
        for (final isMount in [true, false]) {
          for (final host in [_onion, 'a.b.Onion.', 'onion']) {
            expect(
              ProxyCoverageEngine.coverageFor(
                binding: binding,
                proxyConfigured: false,
                destination: Host(host),
                isMountNavigation: isMount,
              ),
              const OnionNeedsProxy(),
              reason: 'binding=$binding isMount=$isMount host=$host',
            );
          }
        }
      }
    });

    test('LEAK-016: any proxy carries an onion service', () {
      // Tor, built in or external, resolves it; a user's own proxy is handed
      // the name rather than an address, so it is that proxy's to resolve.
      for (final binding in ProxyBinding.values) {
        expect(
          ProxyCoverageEngine.coverageFor(
            binding: binding,
            proxyConfigured: true,
            destination: Host(_onion),
            isMountNavigation: true,
          ),
          const Established(),
          reason: 'binding=$binding',
        );
      }
    });

    test('LEAK-016: a name that only contains "onion" is not one', () {
      for (final host in ['onion.example.com', 'myonion', 'onions']) {
        expect(
          ProxyCoverageEngine.coverageFor(
            binding: ProxyBinding.processWide,
            proxyConfigured: false,
            destination: Host(host),
            isMountNavigation: false,
          ),
          const NotClaimed(),
          reason: host,
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
      // user actually makes. BUG-014 measured the store carrying
      // its proxy throughout, so nothing here is blocked any more.
      final g = gate(ProxyBinding.perSite);
      expect(g.evaluate('https://a/'), const Established());
      expect(g.evaluate('https://a/next'), const Established());
      expect(g.evaluate('https://b/elsewhere'), const Established());
      expect(g.evaluate('http://$_onion/'), const Established());
    });

    test('nothing is ever blocked under a process-wide rule', () {
      final g = gate(ProxyBinding.processWide);
      expect(g.evaluate('https://a/'), const Established());
      expect(g.evaluate('https://b/deep/link'), const Established());
    });

    test('a DEFAULT site is unaffected on every binding', () {
      for (final binding in ProxyBinding.values) {
        final g = ProxyCoverageGate(
          binding: binding,
          proxyConfigured: false,
          mountUrl: 'https://a/',
        );
        expect(g.evaluate('https://a/'), const NotClaimed());
        expect(g.evaluate('https://b/'), const NotClaimed());
        expect(g.evaluateFrame('https://c/'), const NotClaimed());
      }
    });

    test('LEAK-016: a DEFAULT site refuses an onion page and frame', () {
      for (final binding in ProxyBinding.values) {
        final g = ProxyCoverageGate(
          binding: binding,
          proxyConfigured: false,
          mountUrl: 'http://$_onion/',
        );
        expect(g.evaluate('http://$_onion/'), const OnionNeedsProxy(),
            reason: 'the mount itself');
        expect(g.evaluate('https://www.$_onion/login'),
            const OnionNeedsProxy());
        expect(g.evaluateFrame('http://$_onion/embed'),
            const OnionNeedsProxy());
        expect(g.evaluate('about:blank'), const NotClaimed(),
            reason: 'the page a refused first load shows instead');
      }
    });
  });
}
