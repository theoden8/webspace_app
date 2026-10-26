// ViewBlockers is the model's `told`: what each live site webview's native
// interceptor was told (DNS-022). Driven here through DnsBlockService, the
// one writer of the lists it resolves against, with the native attach
// replaced by a recorder.
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/view_blockers.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_outbound.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late DnsBlockService dns;
  late List<ViewAttach> sent;

  final follows = SiteId('follows');
  final asksTwo = SiteId('asks-two');
  final off = SiteId('off');

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    dns = DnsBlockService.instance
      ..resetForTest()
      ..store = MemoryFileStore();
    sent = [];
    dns.views = ViewBlockers(send: sent.add, resolve: dns.effectiveLevelFor);
    final list = [for (var i = 0; i < 1200; i++) 'filler-$i.example'].join('\n');
    outboundHttp = FakeOutbound(responder: (_) => http.Response(list, 200));
  });

  tearDown(() {
    resetOutboundHttp();
    dns.resetForTest();
  });

  void buildAll() {
    dns.views.built(#follows,
        site: follows, siteLevel: null, localCdn: false, contentBlock: true);
    dns.views.built(#asksTwo,
        site: asksTwo, siteLevel: 2, localCdn: false, contentBlock: true);
    dns.views.built(#off,
        site: off, siteLevel: kDnsLevelOff, localCdn: true, contentBlock: true);
  }

  test('a view attaches at the level its site resolves to now', () {
    buildAll();
    expect(dns.views.told, {follows: 0, asksTwo: 0, off: 0});
    expect(sent, isEmpty, reason: 'the build sends its own attach');
  });

  test('an app-wide download tells each view running at the app-wide level',
      () async {
    buildAll();
    expect(await dns.downloadList(1), isTrue);
    expect(dns.views.told, {follows: 1, asksTwo: 1, off: 0});
    expect([for (final a in sent) (a.blockers.site, a.blockers.dnsLevel)],
        unorderedEquals([(follows, 1), (asksTwo, 1)]));
  });

  test('a level a site asks for reaches it once its list lands', () async {
    buildAll();
    await dns.downloadList(1);
    sent.clear();
    expect(await dns.downloadLevel(2), isTrue);
    expect(dns.views.told, {follows: 1, asksTwo: 2, off: 0});
    expect([for (final a in sent) (a.blockers.site, a.blockers.dnsLevel)], [(asksTwo, 2)]);
  });

  test('the clear tells every view off', () async {
    buildAll();
    await dns.downloadList(1);
    await dns.downloadLevel(2);
    sent.clear();
    expect(await dns.downloadList(0), isTrue);
    expect(dns.level, 0);
    expect(dns.downloadedLevels, isEmpty);
    expect(dns.views.told, {follows: 0, asksTwo: 0, off: 0});
    expect([for (final a in sent) (a.blockers.site, a.blockers.dnsLevel)],
        unorderedEquals([(follows, 0), (asksTwo, 0)]));
  });

  test('a view that has gone is told nothing', () async {
    buildAll();
    dns.views.gone(#follows);
    await dns.downloadList(1);
    expect(dns.views.told.containsKey(follows), isFalse);
    expect([for (final a in sent) a.blockers.site], isNot(contains(follows)));
  });

  test('a build attaches with the blockers its view is told again with', () {
    final attach = dns.views.built(#cdn,
        site: follows, siteLevel: null, localCdn: true, contentBlock: false);
    expect(attach, (
      view: #cdn,
      blockers: (
        site: follows,
        dnsLevel: 0,
        localCdn: true,
        contentBlock: false,
      ),
    ));
  });

  test('a view keeps its LocalCDN and filter-list flags when it is told again',
      () async {
    dns.views.built(#cdn,
        site: follows, siteLevel: null, localCdn: true, contentBlock: false);
    await dns.downloadList(1);
    expect(sent.single.blockers.localCdn, isTrue);
    expect(sent.single.blockers.contentBlock, isFalse);
  });

  // The fold asserts the views were told what the model's `told` says, so
  // views that miss a move fail the download, not a later page load.
  test('views not told as the lists move fail the fold', () async {
    dns.views = ViewBlockers(send: sent.add, resolve: (_) => kDnsLevelOff);
    buildAll();
    await expectLater(dns.downloadList(1), throwsA(isA<AssertionError>()));
  });
}
