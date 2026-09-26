import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/global_outbound_proxy.dart';
import 'package:webspace/settings/proxy.dart';

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
    debugPublicIconServicesOverride = null;
    resetOutboundHttp();
    clearFaviconCache();
  });

  Future<void> fetchBothWays(String siteUrl) async {
    await getFaviconUrlStream(siteUrl).drain<void>();
    clearFaviconCache();
    await getFaviconUrl(siteUrl);
  }

  group('ICON-012 F-Droid build asks no third-party icon service', () {
    test('only the site is contacted', () async {
      debugPublicIconServicesOverride = false;
      await fetchBothWays('https://example.com/');
      expect(recorder.hosts, isNotEmpty);
      expect(recorder.hosts.toSet(), {'example.com'});
    });

    test('other builds still ask Google and DuckDuckGo', () async {
      await fetchBothWays('https://example.com/');
      expect(recorder.hosts.toSet(), containsAll(_thirdPartyHosts));
    });
  });
}
