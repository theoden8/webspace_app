// Slot-pool lifecycles seal/scan 16 x 128 KiB AEAD slots per test; loaded CI
// runners have blown the default 30s.
@Timeout(Duration(minutes: 2))
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/block_decision.dart';
import 'package:webspace/services/cookie_isolation.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/domain_claim.dart';
import 'package:webspace/services/outbound_preference.dart';
import 'package:webspace/services/file_store.dart' show StoreKind;
import 'package:webspace/services/file_store_io.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/webview_state_secure_storage.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/webspace_selection_engine.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/settings/external_links.dart';
import 'package:webspace/services/archive_membership_engine.dart';
import 'package:webspace/controllers/page_orphan_sweep.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_list_store.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/orphan_sweep_engine.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings_import_engine.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/archive_harness.dart';
import 'helpers/mock_cookie_manager.dart';
import 'helpers/mock_secure_storage.dart';

/// Active-state byte-identity regression tests (ARCH-001).
///
/// Verifies that the archive feature is feature-isolated: no archive
/// operation perturbs the app-tier state stored in SharedPreferences,
/// and the runtime `isArchiveTier` marker never crosses persistence
/// boundaries (toJson, fromJson without the explicit param).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('isArchiveTier is runtime-only', () {
    test('default model has isArchiveTier=false', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      expect(m.isArchiveTier, isFalse);
    });

    test('toJson does NOT include isArchiveTier', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        isArchiveTier: true,
      );
      final json = m.toJson();
      expect(json.containsKey('isArchiveTier'), isFalse);
    });

    test('fromJson defaults isArchiveTier=false', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      final round = WebViewModel.fromJson(m.toJson(), stateSetterF: null);
      expect(round.isArchiveTier, isFalse);
    });

    test('fromJson respects explicit isArchiveTier=true override', () {
      final m = WebViewModel(initUrl: 'https://example.com');
      final round = WebViewModel.fromJson(m.toJson(),
          stateSetterF: null, isArchiveTier: true);
      expect(round.isArchiveTier, isTrue);
    });

    test('effective getters clamp for archive-tier sites', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        notificationsEnabled: true,
        incognito: false,
        isArchiveTier: true,
      );
      expect(m.effectiveNotificationsEnabled, isFalse);
      // ARCH-006: an archive-tier site is always incognito so its container
      // never writes localStorage/IDB/SW/HTTP-cache to disk in cleartext.
      // setOptions and SitePosture (every webview surface) read
      // effectiveIncognito, not the raw field.
      expect(m.effectiveIncognito, isTrue);
      // Stored values are preserved so the user's preferences round-trip
      // through any future eject flow.
      expect(m.notificationsEnabled, isTrue);
      expect(m.incognito, isFalse);
    });

    test('effective getters pass through for app-tier sites', () {
      final m = WebViewModel(
        initUrl: 'https://example.com',
        notificationsEnabled: true,
        incognito: false,
      );
      expect(m.effectiveNotificationsEnabled, isTrue);
      // App-tier respects the stored incognito value both ways.
      expect(m.effectiveIncognito, isFalse);
      expect(
        WebViewModel(initUrl: 'https://e.com', incognito: true)
            .effectiveIncognito,
        isTrue,
      );
    });

    // persistsNavState is the single gate all three production call sites
    // consult (capture, debounce, cold-start restore in main.dart). An
    // archive-tier site returning true here is exactly the regression that
    // would write `controller.saveState()` bytes to a per-`siteId` file —
    // an ARCH-006 violation — so pin every combination.
    test('persistsNavState is false for archive-tier sites', () {
      final m = WebViewModel(initUrl: 'https://a.test', isArchiveTier: true);
      expect(m.persistsNavState, isFalse);
    });

    test('persistsNavState is false for incognito sites', () {
      final m = WebViewModel(initUrl: 'https://a.test', incognito: true);
      expect(m.persistsNavState, isFalse);
    });

    test('persistsNavState is false for archive-tier even when not incognito',
        () {
      final m = WebViewModel(
        initUrl: 'https://a.test',
        isArchiveTier: true,
        incognito: false,
      );
      expect(m.persistsNavState, isFalse);
    });

    test('persistsNavState is true for a plain app-tier site', () {
      final m = WebViewModel(initUrl: 'https://a.test');
      expect(m.persistsNavState, isTrue);
    });

    // Saved sign-ins live in app-tier secure storage keyed by the cleartext
    // siteId, so an archive-tier site must neither read nor write them.
    test('effectiveHttpAuthMemory is off for archive-tier sites', () {
      expect(
        WebViewModel(initUrl: 'https://a.test', isArchiveTier: true)
            .effectiveHttpAuthMemory,
        HttpAuthMemory.off,
      );
    });

    test('effectiveHttpAuthMemory is read-only for incognito sites', () {
      expect(
        WebViewModel(initUrl: 'https://a.test', incognito: true)
            .effectiveHttpAuthMemory,
        HttpAuthMemory.readOnly,
      );
      expect(
        WebViewModel(initUrl: 'https://a.test').effectiveHttpAuthMemory,
        HttpAuthMemory.readWrite,
      );
    });
  });

  // BUG-035: a store written for every site, with no tier input, carried
  // archive-tier and incognito sites' hosts into plaintext prefs.
  group('Block verdicts write no plaintext preference', () {
    testWidgets('a verdict for any site leaves SharedPreferences as it was',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final dns = DnsBlockService.instance..resetForTest();
      addTearDown(dns.resetForTest);
      for (final host in ['tracker.example', 'cdn.example']) {
        dns.recordVerdict(SiteId('archived-site'),
            query: HostQuery(host), verdict: const Blocked(BlockSource.dns));
        dns.recordVerdict(SiteId('archived-site'),
            query: HostQuery(host), verdict: const Allowed());
      }
      await tester.pump(const Duration(seconds: 5));
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getKeys(), isEmpty);
    });
  });

  group('Archive does not touch SharedPreferences', () {
    test('open/create/close cycle leaves SharedPreferences empty', () async {
      final storage = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final archive = Archive(storage: storage);

      final prefsBefore = await SharedPreferences.getInstance();
      final keysBefore = prefsBefore.getKeys();
      expect(keysBefore, isEmpty,
          reason: 'SharedPreferences should be clean at test start');

      // Run a full lifecycle: create, mutate, close, reopen, close.
      final key1 = _testKey(1);
      final handle1 = await archive.createWithKey(key1);
      handle1.state.sites.add({'siteId': 'a', 'initUrl': 'https://a.test'});
      handle1.state.sites.add({'siteId': 'b', 'initUrl': 'https://b.test'});
      await archive.save(handle1);
      await archive.close(handle1);
      final reopened = await archive.tryOpenWithKey(_testKey(1));
      expect(reopened, isNotNull);
      await archive.close(reopened!);

      // SharedPreferences must remain untouched throughout.
      final prefsAfter = await SharedPreferences.getInstance();
      expect(prefsAfter.getKeys(), isEmpty);
    });
  });

  // ARCH-001 / ARCH-006 at the storage layer: archive persistence is
  // confined to the fixed slot pool (the PDE framework) — it never writes
  // a per-site keyed secure-storage entry, and never writes any file to
  // the application documents directory. This is the coverage that was
  // missing: the rest of the suite asserts the *serialization shape* of
  // app-tier state is archive-neutral, but nothing inspected the real
  // on-disk / secure-storage footprint. A regression that routes archive
  // state through a docs-dir writer or a keyed secure-storage entry —
  // even AES-encrypted, even blinded — fails here.
  group('Archive persistence is confined to the slot pool', () {
    // The pool plus the ARCH-002 salt entry: everything the feature is allowed
    // to put in the keychain, and all of it written at pool init whether or
    // not an archive exists.
    Set<String> poolKeys() => {
          for (var i = 0; i < kArchiveSlotCount; i++)
            'archive_slot_${i.toString().padLeft(2, '0')}',
          kArchiveKdfSaltKey,
        };

    test('a full lifecycle touches only the 16 fixed slot keys', () async {
      final mock = MockFlutterSecureStorage();
      final archive = Archive(storage: ArchiveStorage(secureStorage: mock));
      await archive.ensureInitialized();
      expect(mock.storage.keys.toSet(), equals(poolKeys()),
          reason: 'only the fixed pool exists after init');

      final handle = await archive.createWithKey(_testKey(7));
      handle.state.sites.add(_tabbedSite(SiteId('arch-site')).toArchiveJson());
      handle.state.cookies['arch-site'] = [
        {'name': 'sid', 'value': 'super-secret-session'},
      ];
      await archive.save(handle);
      await archive.close(handle);
      final reopened = await archive.tryOpenWithKey(_testKey(7));
      expect(reopened, isNotNull);
      await archive.close(reopened!);

      // The namespace is STILL exactly the slot pool — no per-site key
      // (cookies, webview-state, proxy password) ever appeared.
      expect(mock.storage.keys.toSet(), equals(poolKeys()),
          reason: 'no per-site secure-storage key may be created');
      // And nothing leaked the archive siteId / cookie value in cleartext;
      // slot bodies are AEAD ciphertext (base64).
      for (final value in mock.storage.values) {
        expect(value.contains('arch-site'), isFalse);
        expect(value.contains('super-secret-session'), isFalse);
        expect(value.contains('arch-site.test'), isFalse,
            reason: 'tab addresses stay inside the ciphertext');
      }
    });

    // ARCH-001 for the salt specifically: it is the one entry the KDF fix adds,
    // and it would break deniability if it appeared only once the user had an
    // archive, or varied in shape with the archive count.
    test('the keychain footprint is identical with zero and with N archives',
        () async {
      final withNone = MockFlutterSecureStorage();
      await Archive(storage: ArchiveStorage(secureStorage: withNone))
          .ensureInitialized();

      final withArchives = MockFlutterSecureStorage();
      final archive =
          Archive(storage: ArchiveStorage(secureStorage: withArchives));
      for (var i = 0; i < 3; i++) {
        final handle = await archive.createWithKey(_testKey(20 + i));
        // TAB-009: holding tabs changes nothing outside the slots either.
        handle.state.sites.add(_tabbedSite(SiteId('s$i')).toArchiveJson());
        await archive.save(handle);
        await archive.close(handle);
      }

      expect(withArchives.storage.keys.toSet(),
          equals(withNone.storage.keys.toSet()),
          reason: 'the entry names must not depend on the archive count');
      expect(withArchives.storage[kArchiveKdfSaltKey]!.length,
          equals(withNone.storage[kArchiveKdfSaltKey]!.length));
      for (final key in withNone.storage.keys) {
        expect(withArchives.storage[key]!.length,
            equals(withNone.storage[key]!.length),
            reason: '$key must be the same size either way');
      }
      // Present on a device that has never held an archive, so its existence
      // says nothing about whether one does.
      expect(withNone.storage.containsKey(kArchiveKdfSaltKey), isTrue);
      expect(
        base64Url.decode(withNone.storage[kArchiveKdfSaltKey]!).length,
        equals(kArchiveKdfSaltEntryLength),
      );
    });

    // KIOSK-005: kiosk mode is one field of the site's JSON, which for an
    // archived site rides inside the slot; the lock itself is derived at
    // launch and stored nowhere.
    test('an archived kiosk site adds nothing outside the slots (KIOSK-005)',
        () async {
      final mock = MockFlutterSecureStorage();
      final archive = Archive(storage: ArchiveStorage(secureStorage: mock));
      final handle = await archive.createWithKey(_testKey(30));
      handle.state.sites.add(
          WebViewModel(initUrl: 'https://kiosk.test', kioskMode: true)
              .toArchiveJson());
      await archive.save(handle);
      await archive.close(handle);
      final reopened = await archive.tryOpenWithKey(_testKey(30));
      expect(reopened!.state.sites.single['kioskMode'], isTrue,
          reason: 'the field rides inside the archive');
      await archive.close(reopened);

      expect(mock.storage.keys.toSet(), equals(poolKeys()));
      for (final value in mock.storage.values) {
        expect(value.contains('kiosk'), isFalse);
      }
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    });

    test('the salt differs per install, so one table cannot cover two devices',
        () async {
      final a = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      final b = ArchiveStorage(secureStorage: MockFlutterSecureStorage());
      await a.ensureInitialized();
      await b.ensureInitialized();
      expect((await a.ensureKdfSalt()).salt,
          isNot(equals((await b.ensureKdfSalt()).salt)));
    });

    test('a full lifecycle leaves the documents tree byte-identical', () async {
      final docs =
          await Directory.systemTemp.createTemp('archive_fs_neutrality');
      try {
        // Establish a legitimate app-tier on-disk footprint: an app-tier
        // site persists webview navigation state to the real encrypted
        // store rooted at our temp docs dir.
        final stateStore = SecureWebViewStateStorage(
          secureStorage: MockFlutterSecureStorage(),
          store: IoFileStore('webview_state', kind: StoreKind.data, overrideRoot: docs),
          versionProvider: () => 'test-v1',
        );
        await stateStore.saveState(
            'app-site', state: Uint8List.fromList([1, 2, 3, 4, 5]));
        final before = await _snapshotDir(docs);
        expect(before, isNotEmpty,
            reason: 'sanity: the app-tier write produced a file to diff against');

        // A full archive lifecycle must write NOTHING under the documents
        // directory — its state lives only in the secure-storage slots.
        final archive =
            Archive(storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
        final handle = await archive.createWithKey(_testKey(8));
        handle.state.sites.add({'siteId': 'arch-site', 'initUrl': 'https://y.test'});
        handle.state.cookies['arch-site'] = [
          {'name': 'sid', 'value': 'secret'},
        ];
        await archive.save(handle);
        await archive.close(handle);
        final reopened = await archive.tryOpenWithKey(_testKey(8));
        await archive.close(reopened!);

        final after = await _snapshotDir(docs);
        expect(after, equals(before),
            reason: 'archive operations must not write to the documents '
                'directory (ARCH-001 / ARCH-006)');
      } finally {
        await docs.delete(recursive: true);
      }
    });
  });

  // SEC-044, ARCH-016: an archived site whose id an app-tier site holds (a
  // backup brought it back) runs under another id while its archive is open.
  // Its state lives in the archive, the app-tier site's under the shared id,
  // so neither the open, nor the page's saves and sweeps while it is open,
  // nor the close may change a byte of the app tier.
  group('An archived site holding an app-tier id leaves the app tier as it was',
      () {
    test('over two opens and closes, the saves and the sweeps', () async {
      final run = await _Clash.start();
      for (var round = 0; round < 2; round++) {
        final r = await run.round();
        expect(r.opened, isNot(_Clash.id), reason: 'round ${round + 1}');
        expect(r.whileOpen, run.before,
            reason: 'round ${round + 1}: open, saved and swept');
        expect(r.afterClose, run.before, reason: 'round ${round + 1}: closed');
        expect(r.afterSweep, run.before,
            reason: 'round ${round + 1}: swept after the close');
        for (final MapEntry(key: store, value: live) in r.liveSets.entries) {
          expect(live, contains(_Clash.id),
              reason: 'round ${round + 1}: $store keeps the app-tier site');
        }
      }
    });

    test('a write under the running id is caught while the archive is open',
        () async {
      final run = await _Clash.start();
      final r = await run.round(
          plant: (h, {required opened}) => h.navStates.saveState(opened.activeStateKey,
              state: Uint8List.fromList([9, 9, 9])));
      expect(r.whileOpen, isNot(run.before));
      expect(r.afterClose, run.before,
          reason: 'the close erases what its sites left under their ids');
    });

    test('a write under the archived id is caught after the close', () async {
      final run = await _Clash.start();
      final r = await run.round(
          plant: (h, {required opened}) => h.navStates.saveState(
              webViewStateKey(_Clash.id, tabId: opened.activeTabId),
              state: Uint8List.fromList([9, 9, 9])));
      expect(r.whileOpen, isNot(run.before));
      expect(r.afterClose, isNot(run.before),
          reason: 'the app-tier site\'s back stack was overwritten');
    });
  });

  group('App-tier filtering at persistence shape', () {
    test('app-tier model list serialises without isArchiveTier sites', () {
      final appA = WebViewModel(initUrl: 'https://a.test');
      final appB = WebViewModel(initUrl: 'https://b.test');
      final archX = WebViewModel(
        initUrl: 'https://x.test',
        isArchiveTier: true,
      );
      final archY = WebViewModel(
        initUrl: 'https://y.test',
        isArchiveTier: true,
      );

      // Mimic the production filter in `_persistSites`.
      final all = [appA, archX, appB, archY];
      final persisted =
          all.where((m) => !m.isArchiveTier).map((m) => jsonEncode(m.toJson())).toList();
      expect(persisted, hasLength(2));
      for (final json in persisted) {
        expect(json.contains('isArchiveTier'), isFalse);
      }
    });

    test('export bytes are equal whether archive sites are interleaved or absent', () {
      final appA = WebViewModel(initUrl: 'https://a.test');
      final appB = WebViewModel(initUrl: 'https://b.test');

      final withoutArchive = [appA, appB]
          .map((m) => jsonEncode(m.toJson()))
          .toList();

      final withArchive = [
        appA,
        WebViewModel(initUrl: 'https://x.test', isArchiveTier: true),
        appB,
        WebViewModel(initUrl: 'https://y.test', isArchiveTier: true),
      ]
          .where((m) => !m.isArchiveTier)
          .map((m) => jsonEncode(m.toJson()))
          .toList();

      expect(withArchive, equals(withoutArchive));
    });

    test('an app-tier site routes to no archive-tier site (LIR-017)', () {
      WebViewModel ddg() => WebViewModel(
            siteId: SiteId('ddg'),
            initUrl: 'https://duckduckgo.com',
            externalLinkMode: ExternalLinkMode.inApp,
            routeOutboundLinks: true,
            outboundPreferences: [
              OutboundPreference(
                claim: DomainClaim.exactHost('github.com'),
                targetSiteId: SiteId('gh'),
              ),
            ],
          );
bool prune(List<WebViewModel> sites, {required Map<String, String> archives}) =>
    OutboundPreferenceGc.pruneAcrossBoundary<WebViewModel>(
      sites,
      siteIdOf: (m) => m.siteId,
      isArchiveTier: (m) => m.isArchiveTier,
      archiveOf: (m) => archives[m.siteId],
      prefsOf: (m) => m.outboundPreferences,
      setPrefs: (m, {required prefs}) => m.outboundPreferences = prefs,
    );

      // The target moved into an open archive.
      final open = ddg();
      expect(
        prune([
          open,
          WebViewModel(
              siteId: SiteId('gh'), initUrl: 'https://github.com', isArchiveTier: true),
        ], archives: {'gh': 'slot'}),
        isTrue,
      );
      // The same archive, closed: its sites are not in the runtime at all.
      final closed = ddg();
      prune([closed], archives: const {});
      expect(jsonEncode(open.toJson()), jsonEncode(closed.toJson()));
    });
  });

  // The legacy cookie engine (used wherever native containers are
  // unsupported) branched on the raw `incognito` field, not
  // `effectiveIncognito`. `_persistSites` filters archive-tier sites
  // out of app-tier persistence, but the engine ran underneath that filter
  // and put an archive site's non-Secure cookies into plaintext
  // SharedPreferences (`cookies_fallback`) keyed by its cleartext siteId —
  // an ARCH-001 byte-identity break the moment an archive is opened.
  group('Legacy cookie engine leaves no app-tier trace for archive sites (ISO-005)', () {
    late MockCookieManager jar;
    late MockCookieSecureStorage storage;
    late CookieIsolationEngine engine;

    setUp(() {
      jar = MockCookieManager();
      storage = MockCookieSecureStorage();
      engine = CookieIsolationEngine(cookieManager: jar, storage: storage);
    });

    test('unloadSiteForDomainSwitch persists nothing for an archive site',
        () async {
      final archived = WebViewModel(
        siteId: SiteId('arch-1'),
        initUrl: 'https://secret.test',
        isArchiveTier: true,
      );
      await jar.setCookie(
        url: Uri.parse('https://secret.test/'),
        name: 'sid',
        value: 'archive-session',
        domain: 'secret.test',
      );

      await engine.unloadSiteForDomainSwitch(
        site: archived,
        world: UnloadWorld(
          engine: engine,
          vars: RuntimeVars.ofSet({archived}),
          answers: (
            spared: () => false,
            disposed: () {},
            picked: () => false,
            gone: () => false,
          ),
        ),
      );

      expect(storage.allStorage, isEmpty);
      expect(archived.cookies, isEmpty);
    });

    test('restoreCookiesForSite skips an archive target and archive siblings',
        () async {
      final appSite = WebViewModel(
        siteId: SiteId('app-1'),
        initUrl: 'https://public.test',
      );
      final archived = WebViewModel(
        siteId: SiteId('arch-1'),
        initUrl: 'https://secret.test',
        isArchiveTier: true,
      );
      await jar.setCookie(
        url: Uri.parse('https://secret.test/'),
        name: 'sid',
        value: 'archive-session',
        domain: 'secret.test',
      );
      await jar.setCookie(
        url: Uri.parse('https://public.test/'),
        name: 'sid',
        value: 'app-session',
        domain: 'public.test',
      );

      // Activating the app-tier site sweeps every loaded site into storage.
      await engine.restoreCookiesForSite(
        site: appSite,
        vars: RuntimeVars.ofSet({appSite, archived}),
        versionAtEntry: 0,
      );
      expect(storage.allStorage.keys.toSet(), equals({'app-1'}));

      // Activating the archive site itself must also write nothing.
      await engine.restoreCookiesForSite(
        site: archived,
        vars: RuntimeVars.ofSet({appSite, archived}),
        versionAtEntry: 0,
      );
      expect(storage.allStorage.containsKey('arch-1'), isFalse);
    });

    test('preDeleteCookieCleanup only erases the archive site entry',
        () async {
      final archived = WebViewModel(
        siteId: SiteId('arch-1'),
        initUrl: 'https://secret.test',
        isArchiveTier: true,
      );

      await engine.preDeleteCookieCleanup(
        deletedModel: archived,
        loaded: {archived},
      );

      // `saveCookiesForSite(id, [])` removes the entry rather than writing
      // one, so a delete stays an erase.
      expect(storage.allStorage, isEmpty);
    });
  });

  // The bugs this group catches: an earlier version of _moveSiteToArchive
  // mutated `webspace.siteIndices` to strip the moved site's position
  // from every webspace. That changed app-tier persisted state as a
  // direct side-effect of an archive operation — a clear ARCH-001
  // violation that the existing neutrality tests missed because they
  // never exercised the move flow at the integration layer. These
  // tests simulate the same model-level operations the move flow
  // performs (flipping isArchiveTier; removing the model from
  // `_webViewModels` on archive close; re-adding at the tail on open)
  // and assert webspace persistence is unchanged across the cycle.
  group('Webspace persistence is invariant across move-to-archive cycle', () {
    test('runtime membership keeps an archived site while the archive is open', () {
      final models = [_siteWithId(SiteId('a')), _siteWithId(SiteId('b')), _siteWithId(SiteId('c'))];
      final ws = Webspace(name: 'Work', siteIds: [SiteId('a'), SiteId('b'), SiteId('c')]);
      _resolveWebspaceIndices([ws], models: models);
      models[1].isArchiveTier = true;
      _resolveWebspaceIndices([ws], models: models);
      expect(ws.siteIds, equals(['a', 'b', 'c']));
      expect(ws.siteIndices, equals([0, 1, 2]));
    });

    test('persisted form never names an archived site (ARCH-001)', () {
      final models = [
        _siteWithId(SiteId('a')),
        _siteWithId(SiteId('b'), archive: true),
        _siteWithId(SiteId('c')),
      ];
      final ws = Webspace(name: 'Work', siteIds: [SiteId('a'), SiteId('b'), SiteId('c')]);
      final archived = {
        for (final m in models)
          if (m.isArchiveTier) m.siteId,
      };
      final persisted =
          ArchiveMembershipEngine.persistable([ws], archivedSiteIds: archived);
      final neverArchived =
          Webspace(id: ws.id, name: 'Work', siteIds: [SiteId('a'), SiteId('c')]);
      expect(
        jsonEncode(persisted.map((w) => w.toJson()).toList()),
        equals(jsonEncode([neverArchived.toJson()])),
        reason: 'plaintext form must be byte-identical to a device that '
            'never held b in this webspace',
      );
      expect(ws.siteIds, equals(['a', 'b', 'c']),
          reason: 'runtime list is untouched');
    });

    test('archive-tier collections never enter the persisted form', () {
      final app = Webspace(name: 'Work', siteIds: [SiteId('a')]);
      final arch = Webspace(name: 'Hidden', siteIds: [SiteId('b')])
        ..isArchiveTier = true;
      final persisted = ArchiveMembershipEngine.persistable([app, arch],
          archivedSiteIds: {SiteId('b')});
      expect(persisted.map((w) => w.id), equals([app.id]));
    });

    test('archive close detaches membership into archive state; reopen re-attaches', () {
      final a = _siteWithId(SiteId('a'));
      final b = _siteWithId(SiteId('b'), archive: true);
      final c = _siteWithId(SiteId('c'));
      final models = [a, b, c];
      final ws = Webspace(name: 'Work', siteIds: [SiteId('a'), SiteId('b'), SiteId('c')]);
      _resolveWebspaceIndices([ws], models: models);

      // Close: the archived site leaves the runtime list and its
      // membership moves into the archive's own encrypted state.
      final membership = ArchiveMembershipEngine.detach([ws], siteIds: {SiteId('b')});
      models.removeWhere((m) => m.isArchiveTier);
      _resolveWebspaceIndices([ws], models: models);
      expect(membership, equals({ws.id: ['b']}));
      expect(ws.siteIds, equals(['a', 'c']));
      expect(ws.siteIndices, equals([0, 1]));
      expect(
        jsonEncode(ws.toJson()),
        equals(jsonEncode(
            Webspace(id: ws.id, name: 'Work', siteIds: [SiteId('a'), SiteId('c')]).toJson())),
        reason: 'post-close JSON equals a webspace that never held b',
      );

      // Open: the archive site re-appends at the tail and its
      // membership comes back from the archive state.
      models.add(b);
      ArchiveMembershipEngine.attach([ws], membership: membership);
      _resolveWebspaceIndices([ws], models: models);
      expect(ws.siteIds, equals(['a', 'c', 'b']));
      expect(ws.siteIndices, equals([0, 1, 2]));
    });

    test('attach skips ids already present and webspaces that are gone', () {
      final ws = Webspace(id: WebspaceId('w1'), name: 'Work', siteIds: [SiteId('a'), SiteId('b')]);
      ArchiveMembershipEngine.attach([ws], membership: {
        WebspaceId('w1'): [SiteId('b'), SiteId('c')],
        WebspaceId('gone'): [SiteId('z')],
      });
      expect(ws.siteIds, equals(['a', 'b', 'c']));
    });

    test('record merges into existing membership without duplicates', () {
      final ws = Webspace(id: WebspaceId('w1'), name: 'Work', siteIds: [SiteId('a'), SiteId('b')]);
      final m = ArchiveMembershipEngine.record(
        [ws],
        siteIds: {SiteId('b')},
        existing: {
          WebspaceId('w1'): [SiteId('b')],
          WebspaceId('w9'): [SiteId('z')],
        },
      );
      expect(m, equals({'w1': ['b'], 'w9': ['z']}));
      expect(ws.siteIds, equals(['a', 'b']), reason: 'record never mutates');
    });

    test('moving a site back out forgets it in the archive state', () {
      final membership = {
        WebspaceId('w1'): [SiteId('b'), SiteId('x')],
        WebspaceId('w2'): [SiteId('b')],
      };
      ArchiveMembershipEngine.forget(membership, siteId: SiteId('b'));
      expect(membership, equals({'w1': ['x']}));
    });

    test('closing an archive updates webspace.siteIndices.length (regression: stale per-webspace site counts after close)', () {
      final a = _siteWithId(SiteId('a'));
      final b = _siteWithId(SiteId('b'), archive: true);
      final c = _siteWithId(SiteId('c'));
      final models = [a, b, c];
      final work = Webspace(name: 'Work', siteIds: [SiteId('a'), SiteId('b'), SiteId('c')]);
      _resolveWebspaceIndices([work], models: models);
      expect(work.siteIndices.length, equals(3),
          reason: 'three members visible while archive is open');

      ArchiveMembershipEngine.detach([work], siteIds: {SiteId('b')});
      models.removeWhere((m) => m.isArchiveTier);
      _resolveWebspaceIndices([work], models: models);

      expect(work.siteIndices.length, equals(2),
          reason: 'archive site must drop out of the runtime view');
      expect(work.siteIds, equals(['a', 'c']),
          reason: 'nothing app-tier remembers b once the archive is closed');
    });
  });

  // Legacy-data migration: webspaces persisted before the siteId
  // refactor stored positional `siteIndices` in JSON.
  // `promoteLegacySiteIndices` resolves those indices against the loaded
  // _webViewModels to populate siteIds. These tests pin the
  // migration's behaviour so a future change to load order or
  // resolution rules can't silently drop pre-existing webspace
  // membership.
  group('Legacy siteIndices migration', () {
    test('migration populates siteIds from positional siteIndices', () {
      final ws = Webspace.fromJson({
        'id': 'legacy',
        'name': 'Work',
        'siteIndices': [0, 2],
      });
      expect(ws.siteIds, isEmpty);
      expect(ws.siteIndices, equals([0, 2]));

      final models = [_siteWithId(SiteId('a')), _siteWithId(SiteId('b')), _siteWithId(SiteId('c'))];
      promoteLegacySiteIndices([ws], sites: models);
      _resolveWebspaceIndices([ws], models: models);

      expect(ws.siteIds, equals(['a', 'c']));
      expect(ws.siteIndices, equals([0, 2]));
      // Post-migration, toJson emits siteIds — the legacy positional
      // form is gone from persisted state.
      expect(ws.toJson().containsKey('siteIndices'), isFalse);
      expect(ws.toJson()['siteIds'], equals(['a', 'c']));
    });

    test('migration is idempotent — already-migrated webspaces untouched', () {
      final ws = Webspace.fromJson({
        'id': 'new',
        'name': 'Work',
        'siteIds': ['a', 'b'],
      });
      final beforeIds = List<String>.from(ws.siteIds);
      final models = [_siteWithId(SiteId('a')), _siteWithId(SiteId('b'))];
      // Migration short-circuits when siteIds is already populated.
      promoteLegacySiteIndices([ws], sites: models);
      expect(ws.siteIds, equals(beforeIds));
    });

    test('migration drops out-of-bounds legacy indices', () {
      // The bug class: a webspace persisted with siteIndices=[0,5,10]
      // on a 3-site app. After upgrade the resolver should drop the
      // out-of-bounds entries rather than crashing.
      final ws = Webspace.fromJson({
        'id': 'legacy',
        'name': 'Work',
        'siteIndices': [0, 5, 10],
      });
      final models = [_siteWithId(SiteId('a')), _siteWithId(SiteId('b')), _siteWithId(SiteId('c'))];
      promoteLegacySiteIndices([ws], sites: models);
      expect(ws.siteIds, equals(['a']));
    });
  });
}

Uint8List _testKey(int seed) {
  return Uint8List.fromList(
    List<int>.generate(32, (i) => (seed * 17 + i * 31) & 0xff),
  );
}

/// Recursive `{relative-path: base64(bytes)}` snapshot of [dir], so two
/// snapshots can be compared with `equals` to assert byte-identity of the
/// whole tree (file set + every file's contents).
Future<Map<String, String>> _snapshotDir(Directory dir) async {
  final out = <String, String>{};
  if (!await dir.exists()) return out;
  await for (final entity in dir.list(recursive: true, followLinks: false)) {
    if (entity is File) {
      final rel = entity.path.substring(dir.path.length);
      out[rel] = base64.encode(await entity.readAsBytes());
    }
  }
  return out;
}

void _resolveWebspaceIndices(
  List<Webspace> webspaces, {
  required List<WebViewModel> models,
}) =>
    WebspaceSelectionEngine.resolveIndices(
        webspaces, siteIdsByPosition: [for (final m in models) m.siteId]);

WebViewModel _siteWithId(SiteId siteId, {bool archive = false}) {
  return WebViewModel(
    siteId: siteId,
    initUrl: 'https://$siteId.test',
    isArchiveTier: archive,
  );
}

/// An archive-tier site with a tab tree, its active tab not the first.
WebViewModel _tabbedSite(SiteId siteId) => WebViewModel(
      siteId: siteId,
      initUrl: 'https://$siteId.test/',
      isArchiveTier: true,
      tabs: [
        SiteTab(id: TabId('root'), url: 'https://$siteId.test/a', title: 'A'),
        SiteTab(
            id: TabId('child'), url: 'https://$siteId.test/a/1', parentId: TabId('root')),
        SiteTab(id: TabId('other'), url: 'https://$siteId.test/b'),
      ],
      activeTabId: TabId('child'),
    );

/// An app-tier site and an archived one under the same id [id], driven
/// through [ArchiveController] and the page's own stores and sweep.
final class _Clash {
  _Clash._(this.h, {required this.before});

  static final id = SiteId('shared');
  static final _w = WebspaceId('w');

  final ArchiveHarness h;

  /// The app tier's bytes with the archive closed.
  final Map<String, Object?> before;

  late final _sites = SiteListStore(
      cookies: h.cookieStore, proxyPasswords: h.proxyPasswords);
  late final _shell = ShellStore(h.runtime);

  /// The archive holds the site and its membership of a webspace; the app
  /// tier holds a site of its own under the same id, with a session, a
  /// proxy password, a back stack and the same membership.
  static Future<_Clash> start() async {
    final h = ArchiveHarness();
    final archived = _site(session: 'archived', password: 'archived-pw');
    h.load([archived]);
    h.runtime.webspaces.add(Webspace(id: _w, name: 'w', siteIds: [id]));
    await h.archives.moveIn(archived);
    await h.archives.closeArchiveOf(archived);

    final restored = _site(session: 'app-tier', password: 'app-tier-pw');
    h.load([restored]);
    h.runtime.webspaces.single.siteIds.add(id);
    await h.navStates.saveState(restored.activeStateKey,
        state: Uint8List.fromList([1, 2, 3]));
    final run = _Clash._(h, before: const {});
    await run._persist();
    return _Clash._(h, before: await run._bytes());
  }

  static WebViewModel _site({required String session, required String password}) =>
      WebViewModel(
        siteId: id,
        initUrl: 'https://shared.test/',
        proxySettings: UserProxySettings(
            type: ProxyType.HTTP, address: 'p:8080', username: 'u',
            password: password),
      )..cookies = [Cookie(name: 'sid', value: session, domain: 'shared.test')];

  /// What the page writes after a change to its lists.
  Future<void> _persist() async {
    await _sites.save(h.runtime.models);
    await _shell.saveWebspaces();
  }

  /// The page's sweep over the stores the harness holds; the live set each
  /// other store would be handed is recorded.
  Future<Map<OrphanStore, Set<SiteId>>> _sweep() async {
    final target = _SweepRecorder(PageOrphanSweep(h.runtime,
        cookieStore: h.cookieStore,
        proxyPasswords: h.proxyPasswords,
        navStates: h.navStates));
    await OrphanSweepEngine.sweep(
      targets: target,
      activeSiteIds: h.runtime.siteIds,
      nonIncognitoSiteIds: h.runtime.nonIncognitoSiteIds,
    );
    return target.live;
  }

  /// Everything the app tier persists here: the preferences, the app
  /// keychain and the back stacks.
  Future<Map<String, Object?>> _bytes() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = await h.navStates.siteIds();
    return {
      'prefs': {for (final k in prefs.getKeys().toList()..sort()) k: prefs.get(k)},
      'keychain': {...h.keychain.storage},
      'navStates': {
        for (final k in keys.toList()..sort())
          k: base64.encode((await h.navStates.loadState(k))!),
      },
    };
  }

  /// The archive opens and its site is used: a new session, a page, its
  /// webspace shown. The page saves, [plant] writes what a forgetful path
  /// would, the page sweeps; then the archive closes and the page saves and
  /// sweeps again.
  Future<
      ({
        SiteId opened,
        Map<String, Object?> whileOpen,
        Map<String, Object?> afterClose,
        Map<String, Object?> afterSweep,
        Map<OrphanStore, Set<SiteId>> liveSets,
      })> round({
    Future<void> Function(ArchiveHarness h, {required WebViewModel opened})? plant,
  }) async {
    expect(await h.archives.open(archivePassphrase), isNotNull);
    final opened = h.runtime.models.singleWhere((m) => m.isArchiveTier);
    expect(h.runtime.webspaces.single.siteIds, containsAll([id, opened.siteId]),
        reason: 'the archive\'s membership comes back under the running id');
    expect(opened.activeTabPersistsNavState, isFalse,
        reason: 'ARCH-006: every back-stack capture passes this gate');
    opened
      ..cookies = [Cookie(name: 'sid', value: 'used', domain: 'shared.test')]
      ..currentUrl = 'https://shared.test/used'
      ..pageTitle = 'Used';
    await _persist();
    await plant?.call(h, opened: opened);
    final liveSets = await _sweep();
    final whileOpen = await _bytes();

    await h.archives.closeArchiveOf(opened);
    expect(h.runtime.models.single.isArchiveTier, isFalse);
    await _persist();
    final afterClose = await _bytes();
    for (final MapEntry(key: store, value: live) in (await _sweep()).entries) {
      liveSets[store] = {...?liveSets[store], ...live};
      expect(live, contains(id), reason: '$store after the close');
    }
    return (
      opened: opened.siteId,
      whileOpen: whileOpen,
      afterClose: afterClose,
      afterSweep: await _bytes(),
      liveSets: liveSets,
    );
  }
}

/// [PageOrphanSweep] for the stores [ArchiveHarness] holds; for the
/// process-wide ones it records the live set it would be handed.
final class _SweepRecorder implements OrphanSweepTargets {
  _SweepRecorder(this._page);

  final PageOrphanSweep _page;
  final live = <OrphanStore, Set<SiteId>>{};

  @override
  Future<void> removeOrphans(OrphanStore store,
      {required Set<SiteId> liveSiteIds}) async {
    live[store] = liveSiteIds;
    switch (store) {
      case OrphanStore.cookies ||
            OrphanStore.proxyPasswords ||
            OrphanStore.webViewState:
        await _page.removeOrphans(store, liveSiteIds: liveSiteIds);
      case OrphanStore.httpAuthCredentials ||
            OrphanStore.htmlImports ||
            OrphanStore.blockStatsSites ||
            OrphanStore.siteIcons ||
            OrphanStore.iconImages:
        break;
    }
  }
}
