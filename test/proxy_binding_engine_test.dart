import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_binding_engine.dart';

/// Which of the two proxy shapes a process runs (PROXY-020).
///
/// The decision is asserted off the platform that produces it, because
/// reading `hostIsIOS` here would answer false on the test host and make
/// every Apple assertion below vacuous.
void main() {
  ProxyBinding binding({
    bool isIOS = false,
    bool isMacOS = false,
    bool developerMode = false,
  }) =>
      ProxyBindingEngine.bindingWhen(
        isIOS: isIOS,
        isMacOS: isMacOS,
        developerMode: developerMode,
      );

  group('PROXY-020 binding selection', () {
    test('Apple ships the process-wide rule, not the per-store one', () {
      expect(binding(isIOS: true), ProxyBinding.processWide);
      expect(binding(isMacOS: true), ProxyBinding.processWide);
    });

    test('developer mode selects the per-store binding on Apple', () {
      expect(binding(isIOS: true, developerMode: true), ProxyBinding.perSite);
      expect(binding(isMacOS: true, developerMode: true), ProxyBinding.perSite);
    });

    test('developer mode does not move any other platform', () {
      // Android's concurrency comes from router mode, Linux's from the
      // container session. Neither reads this gate, and a developer-mode
      // flip that quietly changed their serialisation would be a leak
      // surface nobody asked for.
      expect(binding(developerMode: true), ProxyBinding.processWide);
      expect(binding(), ProxyBinding.processWide);
    });

    test('the default is the serialising one on every platform', () {
      for (final apple in [true, false]) {
        expect(
          binding(isIOS: apple, isMacOS: !apple),
          ProxyBinding.processWide,
          reason: 'a binding that is honoured for only one store per '
              'process must never be what a release picks by itself',
        );
      }
    });
  });
}
