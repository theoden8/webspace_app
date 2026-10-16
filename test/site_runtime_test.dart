import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/mock_secure_storage.dart';
import 'helpers/model_fixture.dart';

WebViewModel _site(SiteId id, {bool archive = false}) => WebViewModel(
  siteId: id,
  initUrl: 'https://$id.test',
  isArchiveTier: archive,
);

/// [ids] as rows, [loaded] and [shown] naming sites by id.
SiteRuntime _runtime(
  List<WebViewModel> sites, {
  List<String> loaded = const [],
  SiteId? shown,
}) {
  final r = SiteRuntime()..applied(SitesLoaded(sites));
  WebViewModel byId(SiteId id) => r.models.singleWhere((m) => m.siteId == id);
  r.seed(
    loaded: [for (final id in loaded) byId(SiteId(id))],
    shown: shown == null ? null : byId(shown),
  );
  return r;
}

List<String> _loadedIds(SiteRuntime r) => [for (final m in r.loaded) m.siteId];

void main() {
  group('SiteRuntime.apply keeps the loaded and shown sites', () {
    test('a delete before the shown site shifts it and the loaded set (LAZY-005)', () {
      final b = _site(SiteId('b'));
      final r = _runtime(
        [_site(SiteId('a')), b, _site(SiteId('c'))],
        loaded: ['c', 'a'],
        shown: SiteId('c'),
      );
      final version = r.activationVersion;
      r.applied(SiteRemoved(b));
      expect(_loadedIds(r), ['c', 'a'], reason: 'LRU order kept');
      expect(r.shown?.siteId, 'c');
      expect(
        r.activationVersion,
        greaterThan(version),
        reason: 'an activation suspended across the shift must bail',
      );
    });

    test('deleting the shown site leaves nothing shown', () {
      final a = _site(SiteId('a'));
      final r = _runtime(
        [a, _site(SiteId('b'))],
        loaded: ['a', 'b'],
        shown: SiteId('a'),
      );
      r.applied(SiteRemoved(a));
      expect(r.current, isNull);
      expect(_loadedIds(r), ['b']);
    });

    test('a move in the "All" order takes the loaded sites with it', () {
      final r = _runtime(
        [_site(SiteId('a')), _site(SiteId('b')), _site(SiteId('c'))],
        loaded: ['a', 'c'],
        shown: SiteId('a'),
      );
      r.applied(const SitesMoved(0, to: 2));
      expect([for (final m in r.models) m.siteId], ['b', 'c', 'a']);
      expect(_loadedIds(r), ['a', 'c']);
      expect(r.shown?.siteId, 'a');
    });

    // An archived site keeps its row (SiteArchived), so closing its archive
    // can remove rows below the app-tier sites that stay. The close used to
    // drop the rows without moving the positions, leaving the shown and
    // loaded positions on the sites that slid into them.
    test(
      'closing an archive keeps the loaded and shown sites on their rows',
      () {
        final r = _runtime(
          [
            _site(SiteId('a')),
            _site(SiteId('x'), archive: true),
            _site(SiteId('b')),
            _site(SiteId('c')),
          ],
          loaded: ['x', 'c', 'b'],
          shown: SiteId('c'),
        );
        r.applied(ArchiveClosed(siteIds: {SiteId('x')}, webspaceIds: {}));
        expect([for (final m in r.models) m.siteId], ['a', 'b', 'c']);
        expect(_loadedIds(r), ['c', 'b']);
        expect(r.shown?.siteId, 'c');
      },
    );

    test('closing the archive of the shown site leaves nothing shown', () {
      final r = _runtime(
        [_site(SiteId('a')), _site(SiteId('x'), archive: true)],
        loaded: ['a', 'x'],
        shown: SiteId('x'),
      );
      r.applied(ArchiveClosed(siteIds: {SiteId('x')}, webspaceIds: {}));
      expect(r.current, isNull);
      expect(_loadedIds(r), ['a']);
    });

    test('closing an archive drops its collections and leaves its view', () {
      final r = _runtime([
        _site(SiteId('a')),
        _site(SiteId('x'), archive: true),
      ]);
      r.webspaces.add(
        Webspace(id: WebspaceId('arch'), name: 'arch', siteIds: [SiteId('x')])
          ..isArchiveTier = true,
      );
      r.selectedWebspaceId = WebspaceId('arch');
      r.applied(
        ArchiveClosed(
          siteIds: {SiteId('x')},
          webspaceIds: {WebspaceId('arch')},
        ),
      );
      expect(r.webspaces, isEmpty);
      expect(r.selectedWebspaceId, WebspaceId.all);
    });

    test('an import replaces every row and loads nothing (LAZY-006)', () {
      final r = _runtime(
        [_site(SiteId('a')), _site(SiteId('b'))],
        loaded: ['a'],
        shown: SiteId('a'),
      );
      r.applied(
        SitesReplaced(
          sites: [_site(SiteId('c'))],
          webspaces: [
            Webspace(id: WebspaceId('w'), name: 'w', siteIds: [SiteId('c')]),
          ],
          selectedWebspaceId: WebspaceId('w'),
        ),
      );
      expect(r.loaded, isEmpty);
      expect(r.current, isNull);
      expect(r.filteredIndices(), [0]);
    });

    test('an import lets go of what the replaced sites ran (PROXY-008)', () async {
      final a = _site(SiteId('a'));
      final r = _runtime([a], loaded: ['a'], shown: SiteId('a'));
      final occupant = a.routeClaim.occupant;
      await ProcessRoute.instance.claim(
        occupant,
        route: (type: ProxyType.HTTP, address: 'p:1', username: null, password: null),
        write: () async {},
      );
      expect(ProcessRoute.instance.occupants, contains(occupant));
      r.applied(
        SitesReplaced(
          sites: [_site(SiteId('b'))],
          webspaces: const [],
          selectedWebspaceId: null,
        ),
      );
      expect(ProcessRoute.instance.occupants, isNot(contains(occupant)),
          reason: 'a site off the list runs on no route, so the next site '
              'to move the rule moves it under nothing');
    });

    test('a new site joins the selected named webspace', () {
      final r = _runtime([_site(SiteId('a'))]);
      r.webspaces.add(
        Webspace(id: WebspaceId('w'), name: 'w', siteIds: [SiteId('a')]),
      );
      r.selectedWebspaceId = WebspaceId('w');
      r.applied(SiteAdded(_site(SiteId('b'))));
      expect(r.webspaces.single.siteIds, ['a', 'b']);
      expect(r.filteredIndices(), [0, 1]);
    });

    test('an opened archive appends and rejoins the collections it left', () {
      final r = _runtime([_site(SiteId('a'))]);
      r.webspaces.add(
        Webspace(id: WebspaceId('w'), name: 'w', siteIds: [SiteId('a')]),
      );
      r.applied(
        ArchiveOpened(
          sites: [_site(SiteId('x'), archive: true)],
          webspaces: const [],
          appTierMembership: {
            WebspaceId('w'): [SiteId('x')],
          },
        ),
      );
      expect(r.models.last.siteId, 'x');
      expect(r.webspaces.single.siteIndices, [0, 1]);
    });
  });

  group('SiteSetChange.effects', () {
    late List<SiteSetChange> changes;
    setUpAll(() async {
      final archive = Archive(
        storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
      );
      final into = await archive.createWithKey(Uint8List(32));
      changes = [
        const SitesEdited(),
        const SiteSettingsSaved(),
        const SiteSettingsClosed(),
        const SitesLoaded([]),
        SiteAdded(_site(SiteId('a'))),
        SiteRemoved(_site(SiteId('a'))),
        const SitesMoved(0, to: 1),
        const SitesReplaced(sites: [], webspaces: [], selectedWebspaceId: null),
        const ArchiveOpened(sites: [], webspaces: [], appTierMembership: {}),
        const ArchiveClosed(siteIds: {}, webspaceIds: {}),
        SiteArchived(_site(SiteId('a')), into: into),
        SiteUnarchived(_site(SiteId('a'))),
      ];
    });
    Set<Type> where(bool Function(SiteSetEffects e) f) => {
      for (final c in changes)
        if (f(c.effects)) c.runtimeType,
    };

    test('archive open and close write nothing app-tier (ARCH-001)', () {
      expect(
        where((e) => e.persists || e.savesWebspaces),
        isNot(contains(ArchiveOpened)),
      );
      expect(
        where((e) => e.persists || e.savesWebspaces),
        isNot(contains(ArchiveClosed)),
      );
    });

    test('every change that can orphan a reference prunes it (LIR-017)', () {
      expect(where((e) => e.prunesReferences), {
        SitesLoaded,
        SiteRemoved,
        SitesReplaced,
        SiteArchived,
        SiteUnarchived,
      });
    });

    test('link tabs follow their opener where the switch can have moved '
        '(LIR-034)', () {
      expect(where((e) => e.followsOpeners), {
        SiteSettingsClosed,
        SitesLoaded,
        SitesReplaced,
      });
    });

    test('hosted tabs that may no longer host close (LIR-023)', () {
      expect(where((e) => e.closesIneligibleTabs), {
        SiteRemoved,
        SiteSettingsClosed,
        SitesLoaded,
        SitesReplaced,
        SiteArchived,
      });
    });

    test('storage is swept where sites leave for good (PAUSE-010)', () {
      expect(where((e) => e.sweepsOrphans), {SiteRemoved, SitesReplaced});
    });

    test('startup writes nothing before first paint', () {
      expect(const SitesLoaded([]).effects.persists, isFalse);
    });
  });
}
