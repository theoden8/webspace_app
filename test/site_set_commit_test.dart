import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/services/archive.dart';
import 'package:webspace/services/archive_storage.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/mock_secure_storage.dart';
import 'helpers/model_fixture.dart';

/// The page's side of a commit, recording what the funnel asked of it and,
/// as the sites were written, whether each had a colour.
final class _Host implements SiteSetCommitHost {
  _Host(this.sites);

  final SiteRuntime sites;
  final calls = <String>[];
  List<int?> written = const [];

  @override
  bool get mounted => true;

  @override
  void rebuild() => calls.add('rebuild');


  @override
  Future<void> closeArchives() async => calls.add('closeArchives');

  @override
  Future<void> recordInArchive(SiteArchived change) async =>
      calls.add('recordIn');

  @override
  void pruneLinkReferences() => calls.add('prune');

  @override
  Future<void> reconcileLinkTabs() async => calls.add('reconcile');

  @override
  Future<void> closeIneligibleHostedTabs() async => calls.add('closeTabs');

  @override
  void screenEmptied() => calls.add('screenEmptied');

  @override
  Future<void> saveSelectedWebspaceId() async => calls.add('saveSelection');

  @override
  Future<void> syncTorHolders() async => calls.add('tor');

  @override
  Future<void> refreshRoutes({WebViewModel? active}) async =>
      calls.add('routes');

  @override
  Future<void> persistSites() async {
    calls.add('persist');
    written = [for (final m in sites.models) m.containerColor];
  }

  @override
  Future<void> saveWebspaces() async => calls.add('saveWebspaces');

  @override
  void backgroundSitesChanged() => calls.add('background');

  @override
  Future<void> sweepOrphans() async => calls.add('sweep');
}

WebViewModel _site(String id, {bool archive = false}) => WebViewModel(
  siteId: SiteId(id),
  initUrl: 'https://$id.test',
  isArchiveTier: archive,
);

void main() {
  late SiteRuntime sites;
  late _Host host;
  late SiteSetCommit commit;

  setUp(() {
    sites = SiteRuntime();
    host = _Host(sites);
    commit = SiteSetCommit(sites, host: host);
  });

  // Which steps a change needs is SiteSetChange.effects (site_runtime_test);
  // the order they run in is the funnel's, the same for every change:
  //   - ARCH-010: open archives seal before an import replaces their rows.
  //   - LIR-017 / LIR-031 before ARCH-001's archive record: references
  //     settle before the archived copy is taken, which is written before
  //     the app tier drops the site.
  //   - TOR-002: the refcount is reconciled ahead of the demo-mode bail in
  //     the writes.
  const order = [
    'closeArchives',
    'rebuild',
    'prune',
    'reconcile',
    'closeTabs',
    'recordIn',
    'screenEmptied',
    'saveSelection',
    'tor',
    'routes',
    'persist',
    'saveWebspaces',
    'background',
    'sweep',
  ];

  test('the funnel runs its steps in one fixed order', () async {
    final archive = Archive(
      storage: ArchiveStorage(secureStorage: MockFlutterSecureStorage()),
    );
    final into = await archive.createWithKey(Uint8List(32));
    final changes = <SiteSetChange Function(WebViewModel a)>[
      (_) => const SitesEdited(),
      (_) => const SiteSettingsSaved(),
      (_) => const SiteSettingsClosed(),
      (_) => SitesLoaded([_site('c')]),
      (_) => SiteAdded(_site('c')),
      SiteRemoved.new,
      (_) => const SitesMoved(0, to: 1),
      (_) => SitesReplaced(
        sites: [_site('c')],
        webspaces: [Webspace(id: WebspaceId('w'), name: 'w', siteIds: [SiteId('c')])],
        selectedWebspaceId: WebspaceId('w'),
      ),
      (_) => const ArchiveOpened(sites: [], webspaces: [], appTierMembership: {}),
      (a) => ArchiveClosed(siteIds: {a.siteId}, webspaceIds: const {}),
      (a) => SiteArchived(a, into: into),
      SiteUnarchived.new,
    ];
    for (final change in changes) {
      sites = SiteRuntime();
      host = _Host(sites);
      commit = SiteSetCommit(sites, host: host);
      final a = _site('a');
      sites.applied(SitesLoaded([a, _site('b')]));
      sites.seed(loaded: [a], shown: a);
      final c = change(a);
      await commit.commit(c);
      final ran = [for (final call in host.calls) if (order.contains(call)) call];
      expect(ran, [for (final step in order) if (ran.contains(step)) step],
          reason: '${c.runtimeType} ran its steps out of order');
      expect(ran, isNotEmpty);
    }
  });

  test('the reconcile (LIR-034) runs before ineligible hosted tabs close',
      () async {
    await commit.commit(
      SitesReplaced(sites: [_site('a')], webspaces: const [], selectedWebspaceId: null),
    );
    expect(host.calls.indexOf('reconcile'), greaterThan(-1));
    expect(host.calls.indexOf('reconcile'),
        lessThan(host.calls.indexOf('closeTabs')),
        reason: 'the host a tab now runs as must still be checked');
  });

  test('every app-tier site has a colour before it is written (TAB-018)',
      () async {
    await commit.commit(SitesLoaded([_site('a'), _site('x', archive: true)]));
    await commit.commit(SiteAdded(_site('b')));
    expect(host.written, hasLength(3));
    expect(host.written[0], isNotNull);
    expect(host.written[2], isNotNull,
        reason: 'every change, startup and import included, colours the '
            'sites it brings, and demo sessions, which never write, draw '
            'marks too');
    expect(host.written[1], isNull,
        reason: 'what the app tier stores never depends on an archive being '
            'open (ARCH-001)');
  });

  test('a delete and an import sweep orphans; an edit does not', () async {
    final a = _site('a');
    await commit.commit(SitesLoaded([a, _site('b')]));
    await commit.commit(const SitesEdited());
    expect(host.calls, isNot(contains('sweep')));
    await commit.commit(SiteRemoved(a));
    expect(host.calls, contains('sweep'));
    host.calls.clear();
    await commit.commit(
      SitesReplaced(sites: [_site('c')], webspaces: const [], selectedWebspaceId: null),
    );
    expect(host.calls, containsAllInOrder(['closeArchives', 'sweep']));
  });

  test('the site on screen leaving empties the screen', () async {
    final a = _site('a');
    await commit.commit(SitesLoaded([a, _site('b')]));
    sites.seed(loaded: [a], shown: a);
    await commit.commit(SiteRemoved(a));
    expect(host.calls, contains('screenEmptied'));
    expect(sites.shown, isNull);
  });
}
