// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/localcdn_service.dart';
import 'package:webspace/services/outbound_http.dart';

import 'helpers/fake_outbound.dart';
import 'helpers/fake_path_provider.dart';

/// cdnjs, answering each request with its own path, so a cached file names
/// the request that filled it.
http.Response _cdnjs(http.Request request) =>
    http.Response(request.url.path, 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  final service = LocalCdnService.instance;

  setUpAll(() async {
    dir = await Directory.systemTemp.createTemp('localcdn_download');
    PathProviderPlatform.instance = FakePathProvider(dir);
    SharedPreferences.setMockInitialValues({});
    await service.initialize();
  });
  tearDownAll(() => dir.delete(recursive: true));

  setUp(service.clearCache);
  tearDown(resetOutboundHttp);

  /// The popular set downloaded with [fetches] answering, and the progress
  /// it reported as (completed, total).
  Future<({int downloaded, List<(int, int)> progress})> download(
      FakeOutbound fetches) async {
    outboundHttp = fetches;
    final progress = <(int, int)>[];
    final downloaded = await service.downloadPopularResources(
        onProgress: (completed, {required total}) =>
            progress.add((completed, total)));
    return (downloaded: downloaded, progress: progress);
  }

  test(
      'LCDN-004: the popular set comes from cdnjs alone, counted as it goes, '
      'and its index is saved where a restart reads it (LCDN-012)', () async {
    final fetches = FakeOutbound(responder: _cdnjs);
    final (:downloaded, :progress) = await download(fetches);

    final total = progress.last.$2;
    expect(downloaded, total);
    expect(service.resourceCount, total);
    expect(progress, [for (var i = 1; i <= total; i++) (i, total)]);
    expect(fetches.requested, hasLength(total));
    for (final url in fetches.requested) {
      expect(url.host, 'cdnjs.cloudflare.com', reason: '$url');
      expect(url.path, startsWith('/ajax/libs/'), reason: '$url');
    }
    expect(await service.getLastUpdated(), isNotNull);

    // A page that names the library on another CDN is served cdnjs's copy.
    final key = service.getCacheKey(
        'https://ajax.googleapis.com/ajax/libs/jquery/3.7.1/jquery.min.js')!;
    final file = File(service.cacheIndexSnapshot[key]!);
    expect(file.readAsStringSync(), '/ajax/libs/jquery/3.7.1/jquery.min.js');
    expect(file.path, startsWith(dir.path),
        reason: 'the files live in the platform cache directory');

    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('localcdn_cache_index')!),
        service.cacheIndexSnapshot);
  });

  test('LCDN-004: an update fetches only what the cache lacks', () async {
    bool missed(Uri url) => url.path.contains('bootstrap');
    final first = await download(FakeOutbound(
        responder: (request) => missed(request.url)
            ? http.Response('', 404)
            : _cdnjs(request)));
    final total = first.progress.last.$2;
    final lacking = first.progress.isEmpty ? 0 : total - first.downloaded;
    expect(lacking, greaterThan(0), reason: 'some of the set failed to come');

    final update = FakeOutbound(responder: _cdnjs);
    final second = await download(update);

    expect(second.downloaded, total);
    expect(update.requested, hasLength(lacking));
    expect(update.requested.every(missed), isTrue,
        reason: 'a resource already cached is not fetched again');
  });
}
