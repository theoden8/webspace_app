import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/url_host.dart';
import 'package:webspace/services/settings_backup.dart';
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/mock_secure_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockFlutterSecureStorage secure;
  late HttpAuthSecureStorage store;

  const alice = HttpAuthCredential(username: 'alice', password: 's3cret');

  setUp(() {
    secure = MockFlutterSecureStorage();
    store = HttpAuthSecureStorage(secureStorage: secure);
    SharedPreferences.setMockInitialValues({});
  });

  group('HttpAuthSecureStorage', () {
    test('save + lookup round-trip per (site, host, realm)', () async {
      await store.save('site-1', Host('nas.example.com'), 'R', alice);

      expect(await store.lookup('site-1', Host('nas.example.com'), 'R'), alice);
      expect(await store.lookup('site-2', Host('nas.example.com'), 'R'), isNull);
      expect(await store.lookup('site-1', Host('other.example.com'), 'R'), isNull);
      expect(await store.lookup('site-1', Host('nas.example.com'), 'Other'), isNull);
    });

    test('saving the same space again replaces the credential', () async {
      await store.save('site-1', Host('h'), 'R', alice);
      await store.save('site-1', Host('h'), 'R',
          const HttpAuthCredential(username: 'alice', password: 'n3w'));

      expect((await store.lookup('site-1', Host('h'), 'R'))?.password, 'n3w');
      expect(await store.countForSite('site-1'), 1);
    });

    test('remove drops one space and deletes the entry when empty', () async {
      await store.save('site-1', Host('h'), 'A', alice);
      await store.save('site-1', Host('h'), 'B', alice);
      await store.remove('site-1', Host('h'), 'A');

      expect(await store.countForSite('site-1'), 1);
      await store.remove('site-1', Host('h'), 'B');
      expect(secure.storage.containsKey('http_auth_credentials'), isFalse);
    });

    test('removeSite forgets every space of one site only', () async {
      await store.save('site-1', Host('h'), 'A', alice);
      await store.save('site-1', Host('h'), 'B', alice);
      await store.save('site-2', Host('h'), 'A', alice);
      await store.removeSite('site-1');

      expect(await store.countForSite('site-1'), 0);
      expect(await store.countForSite('site-2'), 1);
    });

    test('removeOrphaned keeps only live sites', () async {
      await store.save('live', Host('h'), 'R', alice);
      await store.save('gone', Host('h'), 'R', alice);
      await store.removeOrphaned({'live'});

      expect(await store.countForSite('live'), 1);
      expect(await store.countForSite('gone'), 0);
    });

    test('concurrent saves from two webviews both land', () async {
      await Future.wait([
        store.save('site-1', Host('a'), 'R', alice),
        store.save('site-2', Host('b'), 'R', alice),
      ]);

      expect(await store.countForSite('site-1'), 1);
      expect(await store.countForSite('site-2'), 1);
    });

    test('a malformed entry is skipped, not thrown', () async {
      await secure.write(
        key: 'http_auth_credentials',
        value: jsonEncode({
          'site-1': [
            {'host': 'h', 'realm': 'R', 'username': 'alice', 'password': 7},
            {'host': 'h', 'realm': 'S', 'username': 'bob', 'password': 'pw'},
          ],
          'site-2': 'not a list',
        }),
      );

      expect(await store.lookup('site-1', Host('h'), 'R'), isNull);
      expect((await store.lookup('site-1', Host('h'), 'S'))?.username, 'bob');
      expect(await store.countForSite('site-2'), 0);
    });
  });

  test('HTTPAUTH-006: saved sign-ins never appear in exports', () async {
    // The credential lives only in secure storage, so nothing on the model,
    // the site JSON or the exported prefs can carry it. This fails the day
    // someone moves it onto WebViewModel or into an AppPref.
    const userNeedle = 'user-needle-5b1e';
    const passwordNeedle = 'password-needle-93c0';
    final site = WebViewModel(initUrl: 'https://nas.example.com/');
    await store.save(
      site.siteId,
      Host('nas.example.com'),
      'Restricted',
      const HttpAuthCredential(
          username: userNeedle, password: passwordNeedle),
    );
    final prefs = await SharedPreferences.getInstance();

    final exported = SettingsBackupService.exportToJson(
      SettingsBackupService.createBackup(
        webViewModels: [site],
        webspaces: [Webspace.all()],
        themeMode: 0,
        globalPrefs: readExportedAppPrefs(prefs),
      ),
    );

    expect(exported.contains(passwordNeedle), isFalse);
    expect(exported.contains(userNeedle), isFalse);
    expect(jsonEncode(site.toJson()).contains(passwordNeedle), isFalse);
  });
}
