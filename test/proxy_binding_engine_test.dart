import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';

/// Where a per-site proxy is enforced, named once (PROXY-027).
///
/// Asserted on the pure decision rather than on the live getter, because
/// this suite runs on Linux: there `hostIsMacOS` answers false first and
/// every further assertion passes without meaning it.
void main() {
  test('Apple binds per store, Android process-wide', () {
    expect(
        ProxyBindingEngine.bindingWhen(
            isIOS: true, isMacOS: false, isLinux: false),
        ProxyBinding.perSite);
    expect(
        ProxyBindingEngine.bindingWhen(
            isIOS: false, isMacOS: true, isLinux: false),
        ProxyBinding.perSite);
    expect(
        ProxyBindingEngine.bindingWhen(
            isIOS: false, isMacOS: false, isLinux: false),
        ProxyBinding.processWide,
        reason: 'Android has one ProxyController rule, which is not a '
            'per-store binding');
  });

  test('Linux binds per session (PROXY-027)', () {
    // Every site has a WebKitNetworkSession of its own there, its
    // container's or an incognito webview's ephemeral one, and the fork
    // leaves a session that holds a proxy alone when the process-wide
    // override moves; so nothing needs the one rule, and nothing contends.
    // No Linux build lacks those sessions: the fork needs WPE 2.40+.
    expect(
        ProxyBindingEngine.bindingWhen(
            isIOS: false, isMacOS: false, isLinux: true),
        ProxyBinding.perSite);
  });

  test('the Apple decision is not gated on anything else', () {
    // It was, once: the per-store path sat behind developer mode because
    // the belief was that only one store is honoured per process. BUG-014
    // attempts 80 and 90 measured several stores reaching several
    // upstreams at once, so that gate guarded nothing and cost every Apple
    // user their per-site proxy. A gate reintroduced here would fail this.
    for (final isIOS in [true, false]) {
      for (final isMacOS in [true, false]) {
        expect(
          ProxyBindingEngine.bindingWhen(
              isIOS: isIOS, isMacOS: isMacOS, isLinux: false),
          (isIOS || isMacOS) ? ProxyBinding.perSite : ProxyBinding.processWide,
          reason: 'isIOS=$isIOS isMacOS=$isMacOS',
        );
      }
    }
  });

  test('there is no third value for router mode', () {
    // Router mode (PROXY-013) changes what the rule NAMES -- the loopback
    // relay rather than the site's upstream -- not where the rule lives, so
    // it rides whichever binding is in force. A third enum value would
    // conflate the two axes and make the binding depend on runtime state
    // the call sites read separately.
    expect(ProxyBinding.values, [ProxyBinding.perSite, ProxyBinding.processWide]);
  });
}
