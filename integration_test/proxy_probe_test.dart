// WebKit's per-store proxy, asked with nothing else in the way (BUG-014).
//
// Attempt 54 measured, on the launches that went direct, that every WebView
// was on exactly the store it was configured with and that the store still
// reported one proxy configuration when the load started. That exhausts what
// the app side can be asked: the plugin does the same thing whether a site
// proxies or goes direct. What it cannot say is whether WebKit is at fault
// or whether something about the app's own machinery is.
//
// This asks without that machinery. A native probe builds one
// WKWebsiteDataStore, puts one SOCKS5 proxy on it, and loads one URL through
// a bare WKWebView -- no plugin, no containers registry, no settings parser,
// no Flutter webview widget. The SOCKS fixture then says whether the request
// arrived through the proxy, which is an observation rather than an
// inference from a load that failed.
//
// Two store shapes, because they have been stuck together for 54 attempts:
//
//   nonPersistent -- what WebKit's own TEST(WebKit, SOCKS5API) proxies
//                    successfully upstream.
//   identified    -- WKWebsiteDataStore(forIdentifier:), what per-site
//                    containers need and what no upstream test covers.
//
// A split names the culprit: if nonPersistent proxies and identified does
// not, identified stores are the defect and that is a WebKit bug report with
// a five-line repro. If both proxy, the defect is in the app's machinery
// after all and this file is the working baseline to bisect toward. If
// neither proxies, per-store proxying is broken outright and the next
// question is CFNetwork's connectionProxyDictionary path.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/platform/host_platform.dart';
import 'package:webspace/services/webview.dart';
import 'fixture_server.dart';
import 'socks5_fixture.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  // The probe is registered by the macOS Runner only. iOS has no equivalent
  // host for it, so the file is a macOS instrument and says so rather than
  // pretending to cover both.
  final applies = hostIsMacOS;

  void log(String m) {
    // ignore: avoid_print
    print('[proxy-probe] $m');
  }

  const channel = MethodChannel('webspace/proxy_probe');

  late Socks5Fixture socks;
  late HttpServer origin;
  var originHost = '127.0.0.1';
  InternetAddress? routable;
  final verdict = <String>[];

  setUpAll(() async {
    if (!applies) return;
    await PlatformInfo.initialize();
    routable = await nonLoopbackIPv4();
    originHost = routable?.address ?? '127.0.0.1';
    socks = await Socks5Fixture.bind();
    origin = await HttpServer.bind(InternetAddress.anyIPv4, 0);
    listenFixture(origin, (req) async {
      final res = req.response..headers.contentType = ContentType.html;
      res.write('<!doctype html><html><body><p>probe</p></body></html>');
      await res.close();
    });
    log('socks ${socks.port}, origin ${origin.port} on $originHost');
  });

  tearDownAll(() async {
    if (!applies) return;
    log('verdict: ${verdict.join(", ")}');
    await socks.close();
    await origin.close(force: true);
  });

  /// One probe, and what the SOCKS server saw for it. The fixture records
  /// every CONNECT it is asked for, so the reading is "the proxy was used",
  /// not "the origin was not reached".
  Future<void> probe(String label, {required bool identified}) async {
    final before = socks.targets.length;
    final reply = await channel.invokeMapMethod<String, dynamic>('probe', {
      'socksHost': '127.0.0.1',
      'socksPort': socks.port,
      'url': 'http://$originHost:${origin.port}/',
      'identified': identified,
      'identifier': '8f1d5c4e-0000-4000-8000-00000000000${identified ? 1 : 2}',
    });
    final seen = socks.targets.length - before;
    final ok = reply?['ok'] == true;
    final detail = reply?['detail'] ?? 'no reply';
    final configured = reply?['configured'];
    verdict.add('$label->${seen > 0 ? "proxied" : "DIRECT"}');
    log('$label: ok=$ok configured=$configured connects=$seen detail=$detail');
    expect(ok, isTrue, reason: 'the probe could not run: $detail');
  }

  testWidgets('a bare WKWebView proxies through a per-store SOCKS5',
      (tester) async {
    if (!applies) {
      markTestSkipped('the per-store proxy probe is a macOS instrument');
      return;
    }
    expect(routable, isNotNull,
        reason: 'no non-loopback IPv4; Apple never proxies a loopback '
            'destination, so nothing here could be distinguished');

    await probe('nonPersistent', identified: false);
    await probe('identified', identified: true);

    // Deliberately not a pass/fail on proxying: this file's job is to report
    // which shapes proxy, and a red bar here would say only what the rest of
    // the tier already says. The verdict line is the result.
    expect(verdict.length, 2);
  });
}
