import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/archive_ids.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/services/process_route.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/model_names.dart';
import 'package:webspace/services/runtime_vars.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/mock_secure_storage.dart';
import 'helpers/model_fixture.dart';

WebViewModel _site(SiteId id, {bool archive = false}) => WebViewModel(
  siteId: id,
  initUrl: 'https://$id.test',
  isArchiveTier: archive,
);

/// [sites] as an archive opening beside [r]'s lists admits them.
Admitted<WebViewModel> _admitted(SiteRuntime r,
        {required List<WebViewModel> sites}) =>
    Admitted.of(
      [for (final m in sites) m.toArchiveJson()],
      listed: {for (final m in r.models) m.siteId},
      build: (record) => WebViewModel.fromJson(
        record,
        stateSetterF: null,
        isArchiveTier: true,
      ),
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

/// The id view written as a table writes it: through a [Mutable] over it.
void _writeIds(
  SiteRuntime r, {
  required Shared<Iterable<SiteId>> Function(RuntimeVars<SiteId> v) cell,
  required ModelVar variable,
  required List<SiteId> to,
}) => Mutable<Iterable<SiteId>, SiteRuntime>.over(
  variable,
  of: (w) => cell(w.vars),
).becomes(Expr.constant<List<SiteId>, SiteRuntime>(to)).stage(StepContext(r))();

void main() {
  group('the runtime by id (CONT-012)', () {
    test('reads its variables as the ids of the sites it holds', () {
      final r = _runtime(
        [_site(SiteId('a')), _site(SiteId('b'))],
        loaded: ['a', 'b'],
        shown: SiteId('b'),
      );
      expect(r.vars.loaded.value, [SiteId('a'), SiteId('b')]);
      expect(r.vars.current.value, SiteId('b'));
      expect(r.vars.marker.value, isNull);
      expect(r.vars.version.value, r.activationVersion);
    });

    test('a write keeps the site it holds under an id, else names the listed '
        'one', () {
      final r = _runtime(
        [_site(SiteId('a')), _site(SiteId('b'))],
        loaded: ['a'],
      );
      final held = r.loaded.single;
      _writeIds(r,
          cell: (v) => v.loaded,
          variable: ModelVar.loaded,
          to: [SiteId('a'), SiteId('b')]);
      expect(r.loaded.first, same(held),
          reason: 'an id the runtime holds keeps its object');
      expect(r.loaded.last, same(r.byId(SiteId('b'))));
    });

    test('a write naming no listed site fails at the write', () {
      final r = _runtime([_site(SiteId('a'))]);
      expect(
        () => _writeIds(r,
            cell: (v) => v.loaded,
            variable: ModelVar.loaded,
            to: [SiteId('gone')]),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('SiteRuntime.apply keeps the loaded and shown sites', () {
    test('a removal names its site by id, whatever object carries the id '
        '(CONT-012)', () {
      final r = _runtime(
        [_site(SiteId('a')), _site(SiteId('b'))],
        loaded: ['a', 'b'],
        shown: SiteId('b'),
      );
      r.applied(SiteRemoved(_site(SiteId('a'))));
      expect(
        [for (final m in r.models) m.siteId],
        ['b'],
        reason: 'an import lists a new object under a carried id while a '
            'flow in flight holds the old one; the model removes by id',
      );
      expect(_loadedIds(r), ['b']);
    });

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

    test(
        'WEBSPACE-010: a delete takes the site out of every webspace and '
        'shifts the positions after it', () {
      final c = _site(SiteId('c'));
      final r = _runtime(
          [_site(SiteId('a')), _site(SiteId('b')), c, _site(SiteId('d'))]);
      final work = Webspace(name: 'Work', siteIds: [SiteId('a'), SiteId('c')]);
      final personal =
          Webspace(name: 'Personal', siteIds: [SiteId('c'), SiteId('d')]);
      r.webspaces.addAll([work, personal]);
      r.resolveWebspaceIndices();
      expect(work.siteIndices, [0, 2]);
      expect(personal.siteIndices, [2, 3]);

      r.applied(SiteRemoved(c));

      expect(work.siteIds, [SiteId('a')]);
      expect(personal.siteIds, [SiteId('d')]);
      expect(work.siteIndices, [0]);
      expect(personal.siteIndices, [2], reason: 'd moved up from 3');
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

    test('a site that leaves the list leaves the tabs it opened following '
        'nothing, in that commit (LIR-034)', () {
      final a = _site(SiteId('a'));
      final b = _site(SiteId('b'));
      final opened = SiteTab(
        url: 'https://c.test/x',
        homeUrl: 'https://c.test/x',
        openerSiteId: a.siteId,
        hostSiteId: a.siteId,
      );
      b.setTabs([...b.tabs, opened]);
      final r = _runtime([a, b]);
      r.applied(SiteRemoved(a));
      expect(opened.openerSiteId, isNull);
      expect(opened.followsOpener, isFalse);
      expect(opened.hostSiteId, a.siteId,
          reason: 'it keeps the site it runs as; LIR-023 decides whether it '
              'may stay');
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
        r.applied(ArchiveClosed(sites: [r.models.singleWhere((m) => m.siteId == SiteId('x'))], webspaceIds: {}));
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
      r.applied(ArchiveClosed(sites: [r.models.singleWhere((m) => m.siteId == SiteId('x'))], webspaceIds: {}));
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
          sites: [r.models.singleWhere((m) => m.siteId == SiteId('x'))],
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

    test(
        'a new site joins exactly the named webspaces picked for it, '
        'not the selected one (EDIT-012)', () {
      final r = _runtime([_site(SiteId('a'))]);
      r.webspaces.addAll([
        Webspace(id: WebspaceId('w'), name: 'w', siteIds: [SiteId('a')]),
        Webspace(id: WebspaceId('h'), name: 'h', siteIds: []),
      ]);
      r.selectedWebspaceId = WebspaceId('w');
      r.applied(SiteAdded(_site(SiteId('b')), joins: {WebspaceId('h')}));
      expect(r.webspaces.first.siteIds, ['a']);
      expect(r.webspaces.last.siteIds, ['b']);
      r.applied(SiteAdded(_site(SiteId('c')), joins: const {}));
      expect(r.webspaces.first.siteIds, ['a']);
      expect(r.webspaces.last.siteIds, ['b'], reason: 'none picked: All only');
    });

    test('an opened archive appends and rejoins the collections it left', () {
      final r = _runtime([_site(SiteId('a'))]);
      r.webspaces.add(
        Webspace(id: WebspaceId('w'), name: 'w', siteIds: [SiteId('a')]),
      );
      r.applied(
        ArchiveOpened(
          sites: _admitted(r, sites: [_site(SiteId('x'), archive: true)]),
          webspaces: const [],
          appTierMembership: {
            WebspaceId('w'): [SiteId('x')],
          },
          rebuilt: (_) {},
        ),
      );
      expect(r.models.last.siteId, 'x');
      expect(r.webspaces.single.siteIndices, [0, 1]);
    });

    test('ARCH-016: an archived site whose id a listed site holds joins under its own '
        '(SEC-044)', () {
      final r = _runtime([_site(SiteId('a')), _site(SiteId('b'))]);
      final opened = _admitted(r, sites: [
        _site(SiteId('a'), archive: true),
        _site(SiteId('c'), archive: true),
      ]);
      r.applied(ArchiveOpened(
        sites: opened,
        webspaces: const [],
        appTierMembership: const {},
        rebuilt: (_) {},
      ));
      final ids = [for (final m in r.models) m.siteId];
      expect(ids.toSet(), hasLength(ids.length), reason: 'ids stay unique');
      expect(ids.sublist(0, 2), ['a', 'b'], reason: 'the app tier keeps its');
      expect(opened.ids.archived(ids[2]), 'a',
          reason: 'sealed back under the id it was archived under');
      expect(ids[3], 'c', reason: 'an id nobody holds is kept');
    });

    test('ARCH-016: a site never joins under an id a listed site holds', () {
      final r = _runtime([_site(SiteId('a'))]);
      expect(() => r.applied(SiteAdded(_site(SiteId('a')))),
          throwsA(isA<AssertionError>()));
    });

    test('the startup load fills the empty list Init starts from', () {
      final r = _runtime([_site(SiteId('a'))]);
      expect(() => r.applied(SitesLoaded([_site(SiteId('b'))])),
          throwsA(isA<AssertionError>()));
    });

    test('a change to what the model does not hold writes none of it', () {
      final a = _site(SiteId('a'));
      final r = _runtime([a, _site(SiteId('b'))], loaded: ['a'], shown: SiteId('a'));
      for (final change in <FunnelChange>[
        const SitesEdited(),
        const SiteSettingsSaved(),
        const SiteSettingsClosed(),
        SiteUnarchived(a),
      ]) {
        r.apply(change, commit: SiteSetCommit.commitOf(change));
      }
      expect(
        () => r.apply(const SitesMoved(0, to: 1), commit: const Commit.none()),
        throwsA(isA<AssertionError>()),
        reason: 'a change that moves the list writes rows',
      );
      r.apply(SiteAdded(_site(SiteId('c'))), commit: const Commit.none());
      expect(r.models.map((m) => m.siteId), contains(SiteId('c')),
          reason: 'a join writes in its own step (JoinTable), not the '
              "change's commit");
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
        ArchiveOpened(
          sites: Admitted.of(const [],
              listed: const {}, build: (_) => throw StateError('none')),
          webspaces: const [],
          appTierMembership: const {},
          rebuilt: (_) {},
        ),
        const ArchiveClosed(sites: [], webspaceIds: {}),
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
