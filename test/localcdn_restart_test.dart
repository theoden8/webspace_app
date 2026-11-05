// ignore_for_file: depend_on_referenced_packages

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/localcdn_service.dart';

import 'helpers/fake_path_provider.dart';

/// Its own file, so the service starts here as on a launch: the index a
/// previous run saved is all it has.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
      'LCDN-012: a launch serves the cache the last run saved, less the files '
      'that are gone', () async {
    final dir = await Directory.systemTemp.createTemp('localcdn_restart');
    addTearDown(() => dir.delete(recursive: true));
    PathProviderPlatform.instance = FakePathProvider(dir);
    final kept = File('${dir.path}/jquery__3.7.1__jquery.min.js')
      ..writeAsStringSync('/* jquery */');
    final saved = {
      'jquery/3.7.1/jquery.min.js': kept.path,
      'vue/3.4.21/vue.global.prod.min.js': '${dir.path}/gone.js',
    };
    SharedPreferences.setMockInitialValues(
        {'localcdn_cache_index': jsonEncode(saved)});

    final service = await LocalCdnService.instance.initialize();

    expect(service.cacheIndexSnapshot,
        {'jquery/3.7.1/jquery.min.js': kept.path});
    final prefs = await SharedPreferences.getInstance();
    expect(jsonDecode(prefs.getString('localcdn_cache_index')!),
        service.cacheIndexSnapshot,
        reason: 'the index drops what it can no longer serve');
  });
}
