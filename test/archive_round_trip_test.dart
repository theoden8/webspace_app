// Every case seals and scans the 16 x 128 KiB slot pool several times
// (same reason as archive_test.dart).
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/cookie_secure_storage.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/archive_harness.dart';
import 'helpers/model_fixture.dart';

/// ARCH-011 / ARCH-012: an archive closed and opened again, or a site moved
/// in and out, brings every site back as it was, and an archive with no room
/// left changes nothing. Driven through [ArchiveController] on the real slot
/// pool; only the platform (keychain, native containers) is faked.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late final AppLocalizations en;
  setUpAll(() async => en = await AppLocalizations.delegate.load(const Locale('en')));

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('closing and opening an archive restores every site as it was (ARCH-004)',
      () async {
    final h = ArchiveHarness();
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

      expect(await h.archives.open(archivePassphrase), isNotNull);
      expect({for (final m in h.runtime.models) m.siteId: _shape(m)}, before,
          reason: 'round ${round + 1}: tabs, active tab and address come '
              'back as sealed, Always open Home and incognito included');
    }
  });

  test('moving a site in and out leaves its tabs as they were', () async {
    final h = ArchiveHarness();
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

  test('a file-import site cannot be moved into an archive (ARCH-006)',
      () async {
    final h = ArchiveHarness();
    final imported =
        WebViewModel(siteId: SiteId('imported'), initUrl: 'file:///notes.html');
    final plain = _away(SiteId('plain'));
    h.load([imported, plain]);

    // A file import's HTML lives only in app-tier HtmlImportStorage, which the
    // archive neither seals nor erases; moving one in would orphan it on
    // app-tier disk (ARCH-001) and lose it to the next orphan sweep. The move
    // is refused before the passphrase prompt, so no archive is touched.
    await h.archives.moveIn(imported);
    expect(imported.isArchiveTier, isFalse);
    expect(h.archives.archiveOf(imported), isNull);
    expect(h.archives.anyOpen, isFalse,
        reason: 'the refused move prompts for no passphrase and opens nothing');

    // The gate is specific to file imports: a plain site still moves in.
    await h.archives.moveIn(plain);
    expect(plain.isArchiveTier, isTrue);
  });

  test('an archive with no room left stays open and unchanged', () async {
    final h = ArchiveHarness();
    final site = _tree(SiteId('big'), active: TabId('c'));
    h.load([site]);
    await h.archives.moveIn(site);
    await h.archives.closeArchiveOf(site);
    await h.archives.open(archivePassphrase);
    final reopened = h.runtime.models.single;
    final sealed = _shape(reopened);

    reopened.setTabs([...reopened.tabs, ..._filler()]);
    await h.archives.closeArchiveOf(reopened);

    expect(h.toasts.last(en), en.homeArchiveFull);
    expect(h.archives.archiveOf(reopened), isNotNull,
        reason: 'the archive stays open');
    expect(h.runtime.models, [reopened]);
    expect(reopened.isArchiveTier, isTrue);
    expect(await _sealedShapes(h), {'big': sealed},
        reason: 'the slot still holds the last state that fitted');

    reopened.setTabs(reopened.tabs.take(4).toList());
    await h.archives.closeArchiveOf(reopened);
    expect(h.toasts.last(en), en.homeArchiveClosed);
    expect(h.runtime.models, isEmpty);
  });

  test('closing every archive reports the one left open', () async {
    final h = ArchiveHarness();
    final site = _tree(SiteId('big'), active: TabId('c'));
    h.load([site]);
    await h.archives.moveIn(site);
    site.setTabs([...site.tabs, ..._filler()]);

    expect(await h.archives.closeAll(), isFalse);
    expect(h.archives.anyOpen, isTrue);
    expect(h.runtime.models, [site]);
  });

  test('a site that does not fit an archive stays where it is', () async {
    final h = ArchiveHarness();
    final small = _tree(SiteId('small'), active: TabId('c'));
    final big = _tree(SiteId('big'), active: TabId('c'))
      ..cookies = [Cookie(name: 'sid', value: 'kept', domain: 'big.test')];
    big.setTabs([...big.tabs, ..._filler()]);
    h.load([small, big]);
    await h.archives.moveIn(small);
    final before = _shape(big);

    await h.archives.moveIn(big);

    expect(h.toasts.last(en), en.homeArchiveFull);
    expect(big.isArchiveTier, isFalse);
    expect(big.archiveContainerKey, isNull);
    expect(big.cookies.single.value, 'kept');
    expect(_shape(big), before);
    expect(h.archives.archiveOf(big), isNull);
    await h.archives.closeArchiveOf(small);
    expect((await _sealedShapes(h)).keys, ['small'],
        reason: 'only the site that fitted is sealed');
  });

  // An archive's operations run one at a time: a close that ran between a
  // move's steps sealed a state the move then changed, or left a site
  // flipped to the archive tier with no archive to hold it.
  // ARCH-013
  test('ARCH-007: an app-tier site holding an archived id keeps its row and '
      'its state across the archive\'s open and close', () async {
    final h = ArchiveHarness();
    final id = SiteId.parse('shared')!;
    final archived = _away(id);
    h.load([archived]);
    await h.archives.moveIn(archived);
    await h.archives.closeArchiveOf(archived);
    expect(h.runtime.models, isEmpty);

    // A backup brings the site back on the app tier under the same id.
    final restored = _away(id);
    h.load([restored]);
    final cookies = CookieSecureStorage(secureStorage: h.keychain);
    await cookies.saveCookiesForSite(id, cookies: [
      cookieFromJson({'name': 'sid', 'value': 'app-tier', 'domain': 'shared.test'}),
    ]);

    expect(await h.archives.open(archivePassphrase), isNotNull);
    expect(h.runtime.models, hasLength(2));
    expect(h.archives.archiveOf(restored), isNull,
        reason: 'the app-tier site is not the archive\'s');
    final opened = h.runtime.models.singleWhere((m) => m.isArchiveTier);
    expect(h.archives.archiveOf(opened), isNotNull);

    await h.archives.closeArchiveOf(opened);
    expect(h.runtime.models, [same(restored)],
        reason: 'the close seals the archive\'s own site, not the app-tier one');
    expect(await cookies.loadCookiesForSite(id), isNotEmpty,
        reason: 'and erases none of the app-tier site\'s state');
    expect(await _sealedShapes(h), hasLength(1));
  });

  test('ARCH-016, SEC-044: an archived site whose id an app-tier site holds runs under '
      'its own while open, and seals back under the archived one', () async {
    final h = ArchiveHarness();
    final id = SiteId.parse('shared')!;
    final archived = _away(id);
    h.load([archived]);
    await h.archives.moveIn(archived);
    final container = archived.archiveContainerKey;
    await h.archives.closeArchiveOf(archived);

    final restored = _away(id);
    h.load([restored]);
    h.runtime.webspaces
        .add(Webspace(id: WebspaceId('w'), name: 'w', siteIds: [id]));

    for (var round = 0; round < 2; round++) {
      expect(await h.archives.open(archivePassphrase), isNotNull);
      final ids = [for (final m in h.runtime.models) m.siteId];
      expect(ids.toSet(), hasLength(2),
          reason: 'round ${round + 1}: two listed sites, two ids');
      final opened = h.runtime.models.singleWhere((m) => m.isArchiveTier);
      expect(opened.siteId, isNot(id));
      expect(opened.archiveContainerKey, container,
          reason: 'its container is still the one sealed under its id');

      await h.archives.closeArchiveOf(opened);
      expect(h.runtime.models, [same(restored)]);
      expect(h.runtime.webspaces.single.siteIds, [id],
          reason: 'the close takes the archive\'s site out of the '
              'collections, not the app-tier one');
      expect((await _sealedShapes(h)).keys, [id],
          reason: 'sealed under the id it was archived under');
    }
  });

  test('ARCH-016: two sites an older build sealed under one id run under two, '
      'each with a container of its own, and seal apart', () async {
    final h = ArchiveHarness();
    final id = SiteId.parse('shared')!;
    final first = _away(id);
    h.load([first]);
    await h.archives.moveIn(first);
    await h.archives.closeArchiveOf(first);
    await h.sealBeside(
        (_away(id)..currentUrl = 'https://shared.test/second').toArchiveJson());

    Set<String?> containers() =>
        {for (final m in h.runtime.models) m.archiveContainerKey?.toString()};
    expect(await h.archives.open(archivePassphrase), isNotNull);
    expect({for (final m in h.runtime.models) m.siteId}, hasLength(2));
    expect(containers(), hasLength(2));
    final ids = {for (final m in h.runtime.models) m.siteId};

    await h.archives.closeArchiveOf(h.runtime.models.first);
    final sealed = [for (final s in await h.sealedSites()) s['siteId']];
    expect(sealed.toSet(), hasLength(2), reason: 'sealed apart');
    expect(sealed, contains(id.toString()));

    expect(await h.archives.open(archivePassphrase), isNotNull);
    expect({for (final m in h.runtime.models) m.siteId}, ids,
        reason: 'the second keeps the id it was given');
    expect(containers(), hasLength(2));
  });

  group('archive operations one at a time', () {
    test('a close while a move reads cookies seals the moved site too',
        () async {
      final h = ArchiveHarness();
      final first = _tree(SiteId('first'), active: TabId('c'));
      final second = _tree(SiteId('second'), active: TabId('c'))
        ..cookies = [Cookie(name: 'sid', value: 'kept', domain: 'second.test')];
      h.load([first, second]);
      await h.archives.moveIn(first);
      final handle = h.archives.archiveOf(first)!;

      final reading = h.holdCookies();
      final move = h.archives.moveIn(second);
      await reading.started;
      final close = h.archives.close(handle);
      reading.release();
      await move;
      expect(await close, isTrue);

      expect(h.runtime.models, isEmpty);
      expect((await _sealedShapes(h)).keys.toSet(), {'first', 'second'});
    });

    test('two closes at once seal once', () async {
      final h = ArchiveHarness();
      final site = _tree(SiteId('only'), active: TabId('c'));
      h.load([site]);
      await h.archives.moveIn(site);
      final handle = h.archives.archiveOf(site)!;
      final results = await Future.wait(
          [h.archives.close(handle), h.archives.close(handle)]);
      expect(results, [true, true]);
      expect(h.runtime.models, isEmpty);
      expect((await _sealedShapes(h)).keys, ['only']);
    });

    test('an open during a close brings the archive back once', () async {
      final h = ArchiveHarness();
      final site = _tree(SiteId('only'), active: TabId('c'));
      h.load([site]);
      await h.archives.moveIn(site);
      final handle = h.archives.archiveOf(site)!;
      final close = h.archives.close(handle);
      final open = h.archives.open(archivePassphrase);
      await close;
      expect(await open, isNotNull);
      expect([for (final m in h.runtime.models) m.siteId], ['only']);
      expect(h.archives.archiveOf(h.runtime.models.single), isNotNull);
    });
  });
}

/// The sites a tab tree can belong to: plain, Always open Home and
/// incognito (each with a tree, and alone on a page away from home), kiosk
/// and tabs off. Every tree has its active tab past the first.
List<WebViewModel> _everyKind() => [
      _tree(SiteId('plain'), active: TabId('c')),
      _tree(SiteId('home'), active: TabId('c'))..alwaysOpenHome = true,
      _away(SiteId('home-one'))..alwaysOpenHome = true,
      _tree(SiteId('private'), active: TabId('c'))..incognito = true,
      _away(SiteId('private-one'))..incognito = true,
      _tree(SiteId('kiosk'), active: TabId('b'))..kioskMode = true,
      _tree(SiteId('no-tabs'), active: TabId('b'))..tabsEnabled = false,
    ];

WebViewModel _tree(SiteId id, {required TabId active}) {
  final at = DateTime.fromMillisecondsSinceEpoch(1700000000000);
  return WebViewModel(
    siteId: id,
    initUrl: 'https://$id.test/',
    tabs: [
      SiteTab(
          id: TabId('a'), url: 'https://$id.test/a', title: 'A',
          createdAt: at, lastActiveAt: at),
      SiteTab(
          id: TabId('b'), url: 'https://$id.test/a/1', parentId: TabId('a'),
          createdAt: at, lastActiveAt: at),
      SiteTab(
          id: TabId('c'), url: 'https://$id.test/a/1/x', title: 'X', parentId: TabId('b'),
          createdAt: at, lastActiveAt: at),
      SiteTab(
          id: TabId('d'), url: 'https://$id.test/b', homeUrl: 'https://$id.test/',
          createdAt: at, lastActiveAt: at),
    ],
    activeTabId: active,
  );
}

/// One tab, on a page other than home.
WebViewModel _away(SiteId id) =>
    WebViewModel(siteId: id, initUrl: 'https://$id.test/')
      ..currentUrl = 'https://$id.test/deep/page'
      ..pageTitle = 'Deep page';

/// More tab records than one slot holds.
List<SiteTab> _filler() => [
      for (var i = 0; i < 600; i++)
        SiteTab(
          id: TabId('f$i'),
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

/// The shapes the slot holds now, by the id each is sealed under.
Future<Map<String, String>> _sealedShapes(ArchiveHarness h) async => {
      for (final json in await h.sealedSites())
        json['siteId'] as String: _shape(WebViewModel.fromJson(json,
            stateSetterF: null, isArchiveTier: true)),
    };
