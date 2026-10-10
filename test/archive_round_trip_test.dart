// Every case seals and scans the 16 x 128 KiB slot pool several times
// (same reason as archive_test.dart).
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_crypto.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/proxy_password_secure_storage.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/webview_state_storage.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_container_native.dart';
import 'helpers/mock_secure_storage.dart';

/// ARCH-011 / ARCH-012: an archive closed and opened again, or a site moved
/// in and out, brings every site back as it was, and an archive with no room
/// left changes nothing. Driven through [ArchiveController] on the real slot
/// pool; only the platform (keychain, native containers) is faked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('closing and opening an archive restores every site as it was',
      () async {
    final h = _Harness();
    final sites = _everyKind();
    h.load(sites);
    final before = {for (final m in sites) m.siteId: _shape(m)};

    for (final m in sites) {
      await h.archives.moveIn(m);
    }
    expect(h.runtime.models.every((m) => m.isArchiveTier), isTrue);

    for (var round = 0; round < 2; round++) {
      await h.archives.closeArchiveOf(h.runtime.models.first);
      expect(h.runtime.models, isEmpty);
      expect(h.toasts.last(en), en.homeArchiveClosed);

      expect(await h.archives.open(_passphrase), isNotNull);
      expect({for (final m in h.runtime.models) m.siteId: _shape(m)}, before,
          reason: 'round ${round + 1}: tabs, active tab and address come '
              'back as sealed, Always open Home and incognito included');
    }
  });

  test('moving a site in and out leaves its tabs as they were', () async {
    final h = _Harness();
    final sites = _everyKind();
    h.load(sites);
    final before = {for (final m in sites) m.siteId: _shape(m)};

    for (final m in sites) {
      await h.archives.moveIn(m);
      await h.archives.moveOut(m);
      expect(m.isArchiveTier, isFalse);
      expect(_shape(m), before[m.siteId], reason: m.siteId);
    }
  });

  test('an archive with no room left stays open and unchanged', () async {
    final h = _Harness();
    final site = _tree('big', active: 'c');
    h.load([site]);
    await h.archives.moveIn(site);
    await h.archives.closeArchiveOf(site);
    await h.archives.open(_passphrase);
    final reopened = h.runtime.models.single;
    final sealed = _shape(reopened);

    reopened.tabs = [...reopened.tabs, ..._filler()];
    await h.archives.closeArchiveOf(reopened);

    expect(h.toasts.last(en), en.homeArchiveFull);
    expect(h.archives.archiveOf(reopened), isNotNull,
        reason: 'the archive stays open');
    expect(h.runtime.models, [reopened]);
    expect(reopened.isArchiveTier, isTrue);
    expect(await h.sealedShapes(), {'big': sealed},
        reason: 'the slot still holds the last state that fitted');

    reopened.tabs = reopened.tabs.take(4).toList();
    await h.archives.closeArchiveOf(reopened);
    expect(h.toasts.last(en), en.homeArchiveClosed);
    expect(h.runtime.models, isEmpty);
  });

  test('closing every archive reports the one left open', () async {
    final h = _Harness();
    final site = _tree('big', active: 'c');
    h.load([site]);
    await h.archives.moveIn(site);
    site.tabs = [...site.tabs, ..._filler()];

    expect(await h.archives.closeAll(), isFalse);
    expect(h.archives.anyOpen, isTrue);
    expect(h.runtime.models, [site]);
  });

  test('a site that does not fit an archive stays where it is', () async {
    final h = _Harness();
    final small = _tree('small', active: 'c');
    final big = _tree('big', active: 'c')
      ..cookies = [Cookie(name: 'sid', value: 'kept', domain: 'big.test')];
    big.tabs = [...big.tabs, ..._filler()];
    h.load([small, big]);
    await h.archives.moveIn(small);
    final before = _shape(big);

    await h.archives.moveIn(big);

    expect(h.toasts.last(en), en.homeArchiveFull);
    expect(big.isArchiveTier, isFalse);
    expect(big.archiveContainerId, isNull);
    expect(big.cookies.single.value, 'kept');
    expect(_shape(big), before);
    expect(h.archives.archiveOf(big), isNull);
    await h.archives.closeArchiveOf(small);
    expect((await h.sealedShapes()).keys, ['small'],
        reason: 'only the site that fitted is sealed');
  });
}

const _passphrase = 'correct horse';

/// The sites a tab tree can belong to: plain, Always open Home and
/// incognito (each with a tree, and alone on a page away from home), kiosk
/// and tabs off. Every tree has its active tab past the first.
List<WebViewModel> _everyKind() => [
      _tree('plain', active: 'c'),
      _tree('home', active: 'c')..alwaysOpenHome = true,
      _away('home-one')..alwaysOpenHome = true,
      _tree('private', active: 'c')..incognito = true,
      _away('private-one')..incognito = true,
      _tree('kiosk', active: 'b')..kioskMode = true,
      _tree('no-tabs', active: 'b')..tabsEnabled = false,
    ];

WebViewModel _tree(String id, {required String active}) {
  final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  return WebViewModel(
    siteId: id,
    initUrl: 'https://$id.test/',
    tabs: [
      SiteTab(
          id: 'a', url: 'https://$id.test/a', title: 'A',
          createdAt: at, lastActiveAt: at),
      SiteTab(
          id: 'b', url: 'https://$id.test/a/1', parentId: 'a',
          createdAt: at, lastActiveAt: at),
      SiteTab(
          id: 'c', url: 'https://$id.test/a/1/x', title: 'X', parentId: 'b',
          createdAt: at, lastActiveAt: at),
      SiteTab(
          id: 'd', url: 'https://$id.test/b', homeUrl: 'https://$id.test/',
          createdAt: at, lastActiveAt: at),
    ],
    activeTabId: active,
  );
}

/// One tab, on a page other than home.
WebViewModel _away(String id) =>
    WebViewModel(siteId: id, initUrl: 'https://$id.test/')
      ..currentUrl = 'https://$id.test/deep/page'
      ..pageTitle = 'Deep page';

/// More tab records than one slot holds.
List<SiteTab> _filler() => [
      for (var i = 0; i < 600; i++)
        SiteTab(
          id: 'f$i',
          url: 'https://big.test/${'x' * 200}/$i',
          title: 'Filler $i',
        ),
    ];

/// Everything that decides where a site comes back. A site on its one
/// primary tab stores no tab list, so its tab is its address.
String _shape(WebViewModel m) => jsonEncode({
      'tabs': m.tabsAreDefault ? null : [for (final t in m.tabs) t.toJson()],
      'active': m.activeTabId,
      'url': m.currentUrl,
      'title': m.pageTitle,
      'tabsEnabled': m.tabsEnabled,
      'kiosk': m.kioskMode,
    });

/// Stand-in for Argon2id: a pure function of passphrase and salt, in
/// microseconds (archive_test.dart pins the real derivation).
Future<Uint8List> _derive(String passphrase, {required Uint8List? salt}) {
  final material = Uint8List(32);
  final src = salt ?? Uint8List.fromList(utf8.encode('legacy-salt'));
  for (var i = 0; i < material.length; i++) {
    material[i] = src[i % src.length];
  }
  return ArchiveCrypto.hmac(material, info: passphrase);
}

class _Harness implements ArchiveHost, ArchivePrompts {
  _Harness() {
    archives = ArchiveController(
      runtime,
      host: this,
      prompts: this,
      containers:
          ContainerIsolationEngine(containerNative: MockContainerNative()),
      cookieStore: CookieSecureStorage(secureStorage: keychain),
      proxyPasswords: ProxyPasswordSecureStorage(secureStorage: keychain),
      navStates: InMemoryWebViewStateStorage(),
      archive: Archive(
          storage: ArchiveStorage(secureStorage: slots), deriveKey: _derive),
    );
  }

  final runtime = SiteRuntime();
  final keychain = MockFlutterSecureStorage();
  final slots = MockFlutterSecureStorage();
  late final ArchiveController archives;
  final toasts = <String Function(AppLocalizations)>[];

  void load(List<WebViewModel> sites) => runtime.apply(SitesLoaded(sites));

  /// The shapes the slot holds now, read by a second pool over the same
  /// keychain the way a relaunch would.
  Future<Map<String, String>> sealedShapes() async {
    final fresh =
        Archive(storage: ArchiveStorage(secureStorage: slots), deriveKey: _derive);
    final handle = await fresh.tryOpen(_passphrase);
    final out = {
      for (final json in handle!.state.sites)
        json['siteId'] as String: _shape(WebViewModel.fromJson(
            Map<String, dynamic>.from(json),
            stateSetterF: null,
            isArchiveTier: true)),
    };
    await fresh.close(handle);
    return out;
  }

  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration? duration,
    bool floating = false,
  }) =>
      toasts.add(message);

  /// The archive steps of the page's `_commitSites`: the rows change, then a
  /// moved site's archived copy is written.
  @override
  Future<void> commitSites(SiteSetChange change) async {
    runtime.apply(change);
    if (change case SiteArchived(:final site, :final into)) {
      await archives.recordIn(site, into: into);
    }
  }

  @override
  Future<List<Cookie>> captureCookies(WebViewModel model) async =>
      model.cookies;

  @override
  Future<String?> passphrase(PassphrasePurpose purpose) async => _passphrase;

  @override
  Future<bool> createArchive(PassphrasePurpose purpose) async => true;

  @override
  Future<bool> includeOpenArchives(int count) async => false;
}
