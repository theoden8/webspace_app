import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';

/// Where a per-site proxy is enforced, named once (PROXY-027).
///
/// Asserted on the pure decision rather than on the live getter, because
/// this suite runs on Linux: there `hostIsMacOS` answers false first and
/// every further assertion passes without meaning it.
void main() {
  test('Apple binds per store, everything else process-wide', () {
    expect(ProxyBindingEngine.bindingWhen(isIOS: true, isMacOS: false),
        ProxyBinding.perSite);
    expect(ProxyBindingEngine.bindingWhen(isIOS: false, isMacOS: true),
        ProxyBinding.perSite);
    expect(ProxyBindingEngine.bindingWhen(isIOS: false, isMacOS: false),
        ProxyBinding.processWide,
        reason: 'Android has one ProxyController rule and Linux a default '
            'network session; neither is a per-store binding');
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
          ProxyBindingEngine.bindingWhen(isIOS: isIOS, isMacOS: isMacOS),
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
