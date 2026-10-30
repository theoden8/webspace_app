import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';

/// Where a per-site proxy is enforced, named once (PROXY-027, PROXY-013).
///
/// Asserted on the pure decision rather than on the live getter, because
/// this suite runs on Linux: there `hostIsMacOS` answers false first and
/// every further assertion passes without meaning it.
void main() {
  ProxyBinding on({
    bool isIOS = false,
    bool isMacOS = false,
    bool isLinux = false,
    bool androidContainers = false,
  }) =>
      ProxyBindingEngine.bindingWhen(
        isIOS: isIOS,
        isMacOS: isMacOS,
        isLinux: isLinux,
        androidContainers: androidContainers,
      );

  test('Apple binds per store', () {
    expect(on(isIOS: true), ProxyBinding.perSite);
    expect(on(isMacOS: true), ProxyBinding.perSite);
  });

  test('Android with per-site profiles routes through the relay (PROXY-013)',
      () {
    // Each profile is a network session of its own, so the relay can tell
    // sites apart by the credential each presents: router mode, for the
    // whole run, with no switch and no fallback to the one rule.
    expect(on(androidContainers: true), ProxyBinding.routed);
  });

  test('Android without them keeps one rule for a site\'s own proxy '
      '(PROXY-008)', () {
    // Every site shares one session and one cached proxy credential, so the
    // relay could not tell them apart.
    expect(on(), ProxyBinding.processWide);
  });

  test('Linux binds per session (PROXY-027)', () {
    // Every site has a WebKitNetworkSession of its own there, its
    // container's or an incognito webview's ephemeral one, and the fork
    // leaves a session that holds a proxy alone when the process-wide
    // override moves; so nothing needs the one rule, and nothing contends.
    // No Linux build lacks those sessions: the fork needs WPE 2.40+.
    expect(on(isLinux: true), ProxyBinding.perSite);
  });

  test('the Apple decision is not gated on anything else', () {
    // It was, once: the per-store path sat behind developer mode because
    // the belief was that only one store is honoured per process. BUG-014
    // attempts 80 and 90 measured several stores reaching several
    // upstreams at once, so that gate guarded nothing and cost every Apple
    // user their per-site proxy. A gate reintroduced here would fail this.
    for (final isIOS in [true, false]) {
      for (final isMacOS in [true, false]) {
        for (final androidContainers in [true, false]) {
          expect(
            on(isIOS: isIOS, isMacOS: isMacOS,
                androidContainers: androidContainers),
            (isIOS || isMacOS)
                ? ProxyBinding.perSite
                : (androidContainers
                    ? ProxyBinding.routed
                    : ProxyBinding.processWide),
            reason: 'isIOS=$isIOS isMacOS=$isMacOS '
                'androidContainers=$androidContainers',
          );
        }
      }
    }
  });
}
