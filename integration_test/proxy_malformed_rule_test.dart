// Instance 5: a proxy rule the fork cannot parse must not UNPROXY the store.
//
// `-[WKWebsiteDataStore setProxyConfigurations:]` treats nil *or an empty
// array* as `clearProxyConfigData()`, which strips the proxy off the live
// session. The fork used to build its array by skipping every rule whose
// `toProxyConfiguration()` returned nil and assigning the result
// unconditionally, so one unparseable rule turned "set this site's proxy"
// into "remove this site's proxy". Fixed in the fork:
// `toProxyConfigurations()` returns an optional and yields nil on any
// unusable rule, and both call sites leave the store's existing proxy alone.
//
// WHY THIS ARM BUILDS `inapp.ProxySettings` BY HAND rather than going through
// `WebViewConfig`. The app cannot emit a malformed rule: `splitProxyAddress`
// rejects the address first and `userProxyToInappProxy` returns null, which
// trips the `proxyUnavailable` fail-closed branch instead. So the app has its
// own guard in front of this one, and the fork's contract is only reachable
// from here. Both lines of defence are worth having -- the app's guard is one
// `splitProxyAddress` edit away from letting something through, and this is
// what catches that.
//
// Destinations are `syntheticOrigin()` addresses (caution 1). Nothing routes
// to them, so an arrival at the fixture is the only way a load can succeed:
// if the store were cleared, the navigation would go direct to an address with
// no route and the fixture would see nothing.

import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/container_native.dart';
import 'package:webspace/services/webview.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final applies = hostIsIOS || hostIsMacOS;

  // One destination per navigation: a second load to the same one could ride
  // the first connection and read as "no proxy was asked for".
  const controlDest = 0;
  const afterMalformedDest = 1;

  late Socks5Fixture socks;
  var containers = false;
  var generation = 0;
  final verdict = <String>[];

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-malformed] $m');
  }

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    containers = await ContainerNative.instance.isSupported();
    socks = await Socks5Fixture.bind();
  });

  tearDownAll(() async {
    if (!applies) return;
    log('socks targets=${socks.targets}');
    log('verdict: containers=$containers ${verdict.join(" ")}');
    await socks.close();
  });

  /// Prints what the gate rested on either way (caution 8).
  bool usable() {
    log('applies=$applies containers=$containers '
        'proxySupported=${PlatformInfo.isProxySupported}');
    if (!applies) {
      markTestSkipped('clearProxyConfigData is an Apple path');
      return false;
    }
    expect(PlatformInfo.isProxySupported, isTrue,
        reason: 'proxy support reads unavailable past the floor; '
            'PlatformInfo.initialize() was most likely not awaited');
    return true;
  }

  /// A raw InAppWebView on the site's own container store, so both mounts
  /// share one `WKWebsiteDataStore` and the second can be asked whether the
  /// first mount's proxy is still on it.
  Future<void> mount(
    WidgetTester tester, {
    required int dest,
    required List<inapp.ProxyRule> rules,
  }) async {
    final key = ValueKey('malformed-${generation++}');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 480,
          child: KeyedSubtree(
            key: key,
            child: inapp.InAppWebView(
              initialUrlRequest: inapp.URLRequest(
                url: inapp.WebUri('http://${syntheticOrigin(dest)}/m$dest'),
              ),
              initialSettings: inapp.InAppWebViewSettings(
                containerId: 'ws-proxy-malformed',
                proxySettings: inapp.ProxySettings(proxyRules: rules),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 500));
  }

  bool saw(int dest) =>
      socks.targets.any((t) => t.startsWith('${syntheticOrigin(dest)}:'));

  Future<bool> waitReal(
    WidgetTester tester,
    bool Function() done, {
    required String label,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    var ok = false;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (done()) {
          ok = true;
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      ok = done();
    });
    log('$label -> ${ok ? "ok" : "timeout"}');
    return ok;
  }

  testWidgets('an unparseable rule leaves the store\'s proxy in force',
      (tester) async {
    if (!usable()) return;

    // The control, and it runs first because everything after it is read
    // against it: a well-formed rule on this store must reach the fixture. If
    // it does not, "the malformed mount also reached the fixture" would be
    // unfalsifiable and "it did not" would mean nothing (caution 2).
    await mount(tester, dest: controlDest, rules: [
      inapp.ProxyRule(url: 'socks5://127.0.0.1:${socks.port}'),
    ]);
    final bound = await waitReal(tester, () => saw(controlDest),
        label: 'well-formed rule reaches the fixture');
    verdict.add('control=${bound ? "bound" : "NOT BOUND"}');
    expect(bound, isTrue,
        reason: 'a well-formed proxy rule did not reach the fixture, so this '
            'file cannot tell a retained proxy from a cleared one and none of '
            'its assertions are evidence');

    // Same container, so the same `WKWebsiteDataStore` the control bound. Its
    // rule cannot be parsed: no host, which is one of the cases
    // `toProxyConfiguration()` returns nil for.
    await mount(tester, dest: afterMalformedDest, rules: [
      inapp.ProxyRule(url: 'socks5://'),
    ]);
    final kept = await waitReal(tester, () => saw(afterMalformedDest),
        label: 'navigation after the malformed rule reaches the fixture');
    verdict.add('after-malformed=${kept ? "still proxied" : "NOT PROXIED"}');

    expect(kept, isTrue,
        reason: 'after a rule the fork could not parse, this store\'s '
            'navigation never reached the proxy. The unparseable rule was '
            'assigned as an empty array, which WKWebsiteDataStore treats as '
            'clearProxyConfigData() -- so "set this site\'s proxy" removed it '
            '(BUG-014 instance 5, caution 6)');
  });
}
