import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/mock_secure_storage.dart';

WebViewModel _site(String id, {bool archive = false}) => WebViewModel(
      siteId: id,
      initUrl: 'https://$id.test',
      isArchiveTier: archive,
    );

/// [ids] as rows, [loaded] and [shown] naming sites by id.
SiteRuntime _runtime(
  List<WebViewModel> sites, {
  List<String> loaded = const [],
  String? shown,
}) {
  final r = SiteRuntime()..apply(SitesLoaded(sites));
  int at(String id) => r.models.indexWhere((m) => m.siteId == id);
  r.loaded.addAll([for (final id in loaded) at(id)]);
  r.current = shown == null ? null : at(shown);
  return r;
}

List<String> _loadedIds(SiteRuntime r) =>
    [for (final i in r.loaded) r.models[i].siteId];

void main() {
  group('SiteRuntime.apply keeps positions on their sites', () {
    test('a delete before the shown site shifts it and the loaded set', () {
      final b = _site('b');
      final r = _runtime([_site('a'), b, _site('c')],
          loaded: ['c', 'a'], shown: 'c');
      final version = r.activationVersion;
      r.apply(SiteRemoved(b));
      expect(_loadedIds(r), ['c', 'a'], reason: 'LRU order kept');
      expect(r.shown?.siteId, 'c');
      expect(r.activationVersion, greaterThan(version),
          reason: 'an activation suspended across the shift must bail');
    });

    test('deleting the shown site leaves nothing shown', () {
      final a = _site('a');
      final r = _runtime([a, _site('b')], loaded: ['a', 'b'], shown: 'a');
      r.apply(SiteRemoved(a));
      expect(r.current, isNull);
      expect(_loadedIds(r), ['b']);
    });

    test('a move in the "All" order takes the loaded sites with it', () {
      final r = _runtime([_site('a'), _site('b'), _site('c')],
          loaded: ['a', 'c'], shown: 'a');
      r.apply(const SitesMoved(0, to: 2));
      expect([for (final m in r.models) m.siteId], ['b', 'c', 'a']);
      expect(_loadedIds(r), ['a', 'c']);
      expect(r.shown?.siteId, 'a');
    });

    // An archived site keeps its row (SiteArchived), so closing its archive
    // can remove rows below the app-tier sites that stay. The close used to
    // drop the rows without moving the positions, leaving the shown and
    // loaded positions on the sites that slid into them.
    test('closing an archive keeps the loaded and shown sites on their rows',
        () {
      final r = _runtime(
        [_site('a'), _site('x', archive: true), _site('b'), _site('c')],
        loaded: ['x', 'c', 'b'],
        shown: 'c',
      );
      r.apply(const ArchiveClosed(siteIds: {'x'}, webspaceIds: {}));
      expect([for (final m in r.models) m.siteId], ['a', 'b', 'c']);
      expect(_loadedIds(r), ['c', 'b']);
      expect(r.shown?.siteId, 'c');
    });

    test('closing the archive of the shown site leaves nothing shown', () {
      final r = _runtime([_site('a'), _site('x', archive: true)],
          loaded: ['a', 'x'], shown: 'x');
      r.apply(const ArchiveClosed(siteIds: {'x'}, webspaceIds: {}));
      expect(r.current, isNull);
      expect(_loadedIds(r), ['a']);
    });

    test('closing an archive drops its collections and leaves its view', () {
      final r = _runtime([_site('a'), _site('x', archive: true)]);
      r.webspaces.add(Webspace(id: 'arch', name: 'arch', siteIds: ['x'])
        ..isArchiveTier = true);
      r.selectedWebspaceId = 'arch';
      r.apply(const ArchiveClosed(siteIds: {'x'}, webspaceIds: {'arch'}));
      expect(r.webspaces, isEmpty);
      expect(r.selectedWebspaceId, kAllWebspaceId);
    });

    test('an import replaces every row and loads nothing', () {
      final r = _runtime([_site('a'), _site('b')], loaded: ['a'], shown: 'a');
      r.apply(SitesReplaced(
        sites: [_site('c')],
        webspaces: [Webspace(id: 'w', name: 'w', siteIds: ['c'])],
        selectedWebspaceId: 'w',
      ));
      expect(r.loaded, isEmpty);
      expect(r.current, isNull);
      expect(r.filteredIndices(), [0]);
    });

    test('a new site joins the selected named webspace', () {
      final r = _runtime([_site('a')]);
      r.webspaces.add(Webspace(id: 'w', name: 'w', siteIds: ['a']));
      r.selectedWebspaceId = 'w';
      r.apply(SiteAdded(_site('b')));
      expect(r.webspaces.single.siteIds, ['a', 'b']);
      expect(r.filteredIndices(), [0, 1]);
    });

    test('an opened archive appends and rejoins the collections it left', () {
      final r = _runtime([_site('a')]);
      r.webspaces.add(Webspace(id: 'w', name: 'w', siteIds: ['a']));
      r.apply(ArchiveOpened(
        sites: [_site('x', archive: true)],
        webspaces: const [],
        appTierMembership: const {
          'w': ['x'],
        },
      ));
      expect(r.models.last.siteId, 'x');
      expect(r.webspaces.single.siteIndices, [0, 1]);
    });
  });

  group('SiteSetChange.effects', () {
    late List<SiteSetChange> changes;
    setUpAll(() async {
      final archive = Archive(
          storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()));
      final into = await archive.createWithKey(Uint8List(32));
      changes = [
      const SitesEdited(),
      const SiteSettingsSaved(),
      const SiteSettingsClosed(),
      const SitesLoaded([]),
      SiteAdded(_site('a')),
      SiteRemoved(_site('a')),
      const SitesMoved(0, to: 1),
      const SitesReplaced(sites: [], webspaces: [], selectedWebspaceId: null),
      const ArchiveOpened(sites: [], webspaces: [], appTierMembership: {}),
      const ArchiveClosed(siteIds: {}, webspaceIds: {}),
      SiteArchived(_site('a'), into: into),
      SiteUnarchived(_site('a')),
    ];
    });
    Set<Type> where(bool Function(SiteSetEffects e) f) =>
        {for (final c in changes) if (f(c.effects)) c.runtimeType};

    test('archive open and close write nothing app-tier (ARCH-001)', () {
      expect(where((e) => e.persists || e.savesWebspaces),
          isNot(contains(ArchiveOpened)));
      expect(where((e) => e.persists || e.savesWebspaces),
          isNot(contains(ArchiveClosed)));
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
      expect(where((e) => e.followsOpeners),
          {SiteSettingsClosed, SitesLoaded, SitesReplaced});
    });

    test('hosted tabs that may no longer host close (LIR-023)', () {
      expect(where((e) => e.closesIneligibleTabs), {
        SiteSettingsClosed,
        SitesLoaded,
        SitesReplaced,
        SiteArchived,
      });
    });

    test('storage is swept where sites leave for good', () {
      expect(where((e) => e.sweepsOrphans), {SiteRemoved, SitesReplaced});
    });

    test('startup writes nothing before first paint', () {
      expect(const SitesLoaded([]).effects.persists, isFalse);
    });
  });
}
