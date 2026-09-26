import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/platform/build_flavor.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

/// ICON-012. The flavor is a compile-time constant, so each side runs only in
/// its own build: plain `flutter test` covers other builds, and CI's
/// build-android job reruns this file with `flutter test --flavor fdroid`.
/// scripts/check_no_icon_services.sh checks the built APK.
class _HostRecorder implements OutboundHttpFactory {
  final List<String> hosts = [];

  @override
  OutboundClient clientFor(UserProxySettings settings) =>
      OutboundClientReady(MockClient((request) async {
        hosts.add(request.url.host);
        return http.Response('<html><head></head></html>', 200);
      }));
}

const _thirdPartyHosts = {'www.google.com', 'icons.duckduckgo.com'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _HostRecorder recorder;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    clearFaviconCache();
    recorder = _HostRecorder();
    outboundHttp = recorder;
  });

  tearDown(() {
    resetOutboundHttp();
    clearFaviconCache();
  });

  Future<void> fetchBothWays(String siteUrl) async {
    await getFaviconUrlStream(siteUrl).drain<void>();
    clearFaviconCache();
    await getFaviconUrl(siteUrl);
  }

  test(
    'F-Droid build contacts only the site',
    () async {
      await fetchBothWays('https://example.com/');
      expect(recorder.hosts, isNotEmpty);
      expect(recorder.hosts.toSet(), {'example.com'});
    },
    skip: isFdroidFlavor
        ? false
        : 'F-Droid build only: flutter test --flavor fdroid',
  );

  test(
    'other builds still ask Google and DuckDuckGo',
    () async {
      await fetchBothWays('https://example.com/');
      expect(recorder.hosts.toSet(), containsAll(_thirdPartyHosts));
    },
    skip: isFdroidFlavor ? 'not in the F-Droid build' : false,
  );
}
