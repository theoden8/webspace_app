// Which hosts the icon service asks (ICON-006, ICON-014): Google and
// DuckDuckGo by default, only the site itself under Site icons only.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/screens/add_site.dart' show FaviconUrlCache;
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/global_outbound_proxy.dart';

import 'helpers/fake_outbound.dart';

const _site = 'https://example.com/';
const _google = 'https://www.google.com/s2/favicons?domain=example.com&sz=256';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeOutbound factory;

  Set<String> hosts() => factory.requested.map((u) => u.host).toSet();

  void siteIconsOnly({required bool on}) {
    DeveloperModeService.instance.debugSet(on: on);
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.siteIconsOnly, on: on);
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    clearFaviconCache();
    factory = FakeOutbound(responder: 
        (_) => http.Response('<html><head></head></html>', 200));
    outboundHttp = factory;
  });

  tearDown(() {
    siteIconsOnly(on: false);
    resetOutboundHttp();
    clearFaviconCache();
  });

  test('by default Google and DuckDuckGo are asked', () async {
    await getFaviconUrlStream(_site).drain<void>();
    expect(hosts(), containsAll({'www.google.com', 'icons.duckduckgo.com'}));
  });

  test('under Site icons only every request goes to the site', () async {
    siteIconsOnly(on: true);
    await getFaviconUrlStream(_site).drain<void>();
    expect(hosts(), {'example.com'});
  });

  test('the switch needs developer mode (DEVTOOLS-011)', () async {
    ExperimentalFeaturesService.instance
        .debugSet(ExperimentalFeature.siteIconsOnly, on: true);
    DeveloperModeService.instance.debugSet(on: false);
    expect(publicIconServicesAllowed, isTrue);
  });

  test('a service icon found before the switch is not reused after it',
      () async {
    final before = await getFaviconUrlStream(_site).last;
    expect(before.url, _google);

    siteIconsOnly(on: true);
    factory.requests.clear();
    final after = await getFaviconUrlStream(_site).toList();
    expect(after.map((u) => u.url), isNot(contains(_google)));
    expect(hosts(), {'example.com'});
  });

  test('the switch turned on while DuckDuckGo answers stops the fetch there',
      () async {
    outboundHttp = factory = FakeOutbound(responder: (req) {
      if (req.url.host == 'icons.duckduckgo.com') siteIconsOnly(on: true);
      return http.Response('<html><head></head></html>', 200);
    });
    final updates = await getFaviconUrlStream(_site).toList();
    expect(updates.where((u) => isPublicIconServiceUrl(u.url)), isEmpty);
    expect(hosts(), isNot(contains('www.google.com')));
  });

  test('a service icon sent before the switch went on is not sent as final',
      () async {
    outboundHttp = factory = FakeOutbound(responder: (req) {
      if (req.url.host == 'example.com') siteIconsOnly(on: true);
      return http.Response('<html><head></head></html>', 200);
    });
    final updates = await getFaviconUrlStream(_site).toList();
    expect(
        updates.where((u) => u.isFinal && isPublicIconServiceUrl(u.url)),
        isEmpty);
  });

  test('a service URL kept on disk reads as absent under the switch',
      () async {
    SharedPreferences.setMockInitialValues({
      'favicon_url_$_site': _google,
      'favicon_url_https://other.test/': 'https://other.test/icon.png',
    });
    await FaviconUrlCache.initialize();
    expect(FaviconUrlCache.get(_site), _google);
    siteIconsOnly(on: true);
    expect(FaviconUrlCache.get(_site), isNull);
    expect(FaviconUrlCache.get('https://other.test/'),
        'https://other.test/icon.png');
  });

  test('isPublicIconServiceUrl names only the two services', () {
    expect(isPublicIconServiceUrl(_google), isTrue);
    expect(
        isPublicIconServiceUrl('https://icons.duckduckgo.com/ip3/a.test.ico'),
        isTrue);
    expect(isPublicIconServiceUrl('https://www.google.com/favicon.ico'),
        isFalse);
    expect(isPublicIconServiceUrl('https://example.com/s2/favicons'), isFalse);
  });
}
