import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/global_outbound_proxy.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/widgets/datasets.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_path_provider.dart';

/// The ClearURLs row's dataset over the real service: what a download
/// fetches and keeps, and what the row then says. The row turns the returned
/// message into its SnackBar (dataset_tile_test.dart).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final AppLocalizations en;
  setUpAll(() async => en = await AppLocalizations.delegate.load(const Locale('en')));
  final rules = jsonEncode({
    'providers': {
      'any': {
        'urlPattern': r'example\.com',
        'completeProvider': false,
        'rules': [r'^utm_source$'],
        'rawRules': [],
        'exceptions': [],
        'redirections': [],
      },
    },
  });
  late Directory docs;
  late FakeOutbound outbound;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    GlobalOutboundProxy.resetForTest();
    docs = await Directory.systemTemp.createTemp('clearurl_dataset');
    useFakePathProvider(docs);
    ClearUrlService.instance.resetForTest();
  });
  tearDown(() async {
    resetOutboundHttp();
    ClearUrlService.instance.resetForTest();
    await docs.delete(recursive: true);
  });

  Future<ClearUrlsDataset> dataset() async {
    final d = ClearUrlsDataset();
    addTearDown(d.dispose);
    await Future<void>.delayed(Duration.zero);
    return d;
  }

  test('a download fetches the published rules and keeps them (CURL-001, CURL-010)',
      () async {
    outboundHttp = outbound = FakeOutbound(responder: (_) => http.Response(rules, 200));
    final row = await dataset();
    expect(row.ready, isFalse);
    expect(row.status(en), en.appSettingsNotDownloaded);

    expect(await row.download(en), en.appSettingsClearUrlsUpdated);
    expect(outbound.requested.single.toString(),
        'https://rules2.clearurls.xyz/data.minify.json');
    expect(File('${docs.path}/clearurl_rules.json').readAsStringSync(), rules);
    expect(row.lastUpdated, isNotNull, reason: 'the row names when');
    expect(row.status(en), isNull);
  });

  test('a failed download says so and keeps the rules there were (CURL-001)',
      () async {
    outboundHttp = FakeOutbound(responder: (_) => http.Response(rules, 200));
    final row = await dataset();
    await row.download(en);
    outboundHttp = FakeOutbound(responder: (_) => http.Response('', 503));

    expect(await row.download(en), en.appSettingsClearUrlsDownloadFailed);
    expect(
        ClearUrlService.instance.cleanUrl('https://example.com/p?utm_source=a'),
        'https://example.com/p');
  });
}
