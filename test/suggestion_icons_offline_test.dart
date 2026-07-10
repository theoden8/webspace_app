import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:webspace/screens/add_site.dart' show FaviconImage;
import 'package:webspace/services/bundled_icons.dart';
import 'package:webspace/services/icon_service.dart';
import 'package:webspace/services/suggested_sites_service.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/proxy.dart';

/// Records any attempt to acquire an outbound client. The offline icon path
/// MUST never reach this.
class _RecordingFactory implements OutboundHttpFactory {
  final List<UserProxySettings> queries = [];

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    queries.add(settings);
    return OutboundClientReady(MockClient((_) async => http.Response('', 200)));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('bundled_icons helpers', () {
    test('normalizeIconHost lowercases and strips www.', () {
      expect(normalizeIconHost('WWW.GitHub.com'), 'github.com');
      expect(normalizeIconHost('example.org'), 'example.org');
    });

    test('curated suggestion hosts normalize to unique asset keys', () {
      final keys = kDefaultSuggestions
          .map((s) => normalizeIconHost(Uri.parse(s.url).host))
          .toList();
      expect(keys.toSet().length, keys.length,
          reason: 'asset-key collision across curated suggestions');
    });

    test('bundledIconAssetFor returns null when host not bundled', () {
      expect(bundledIconAssetFor('definitely-not-bundled.example'), isNull);
    });

    test('monogramLetter prefers label, falls back to host', () {
      expect(monogramLetter(label: 'Claude', host: 'claude.ai'), 'C');
      expect(monogramLetter(label: '  ', host: 'github.com'), 'G');
      expect(monogramLetter(label: null, host: '123.example'), '1');
    });

    test('every bundled host belongs to a curated suggestion', () {
      final curated = kDefaultSuggestions
          .map((s) => normalizeIconHost(Uri.parse(s.url).host))
          .toSet();
      for (final host in kBundledIconHosts) {
        expect(curated, contains(host),
            reason: '$host is bundled but not a curated suggestion');
      }
    });

    testWidgets('every bundled host has a loadable committed asset',
        (tester) async {
      for (final host in kBundledIconHosts) {
        final path = bundledIconAssetFor(host);
        expect(path, isNotNull, reason: '$host has no asset path');
        final data = await rootBundle.load(path!);
        expect(data.lengthInBytes, greaterThan(0),
            reason: '$path is empty or unregistered');
      }
    });
  });

  group('offline suggestion icons make no network requests', () {
    setUp(() {
      clearFaviconCache();
    });
    tearDown(() {
      resetOutboundHttp();
      clearFaviconCache();
    });

    testWidgets('rendering the curated suggestions never asks for a client',
        (tester) async {
      final fake = _RecordingFactory();
      outboundHttp = fake;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Wrap(
            children: [
              for (final s in kDefaultSuggestions)
                SizedBox(
                  width: 48,
                  height: 48,
                  child: FaviconImage(
                    domain: s.domain,
                    size: 32,
                    offline: true,
                    label: s.name,
                  ),
                ),
            ],
          ),
        ),
      ));
      await tester.pumpAndSettle();

      expect(fake.queries, isEmpty,
          reason: 'offline suggestions list reached the outbound factory');
    });
  });
}
