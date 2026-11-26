import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/archive_controller.dart';
import 'package:webspace/controllers/site_import.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/controllers/site_set_commit.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/mock_container_native.dart';
import 'helpers/model_fixture.dart';

WebViewModel _site(String id, {required String cookie}) =>
    WebViewModel(siteId: SiteId(id), initUrl: 'https://$id.test/')
      ..cookies = [Cookie(name: cookie, value: id, domain: '$id.test')];

/// The page's commit as the funnel lands it, and a frame that comes at once.
final class _Host implements SiteImportHost {
  _Host(this.sites);

  final SiteRuntime sites;

  @override
  bool get mounted => true;

  @override
  void rebuild() {}

  @override
  void toast(
    String Function(AppLocalizations loc) message, {
    Duration duration = const Duration(seconds: 4),
    bool floating = false,
  }) {}

  @override
  Future<void> commitSites(FunnelChange change) =>
      throw UnsupportedError('an import lands in its own step');

  @override
  SiteSetStage stageSites(SiteDrop drop) => _Stage(sites, drop: drop);

  @override
  Future<void> endOfFrame() async {}
}

final class _Stage implements SiteSetStage {
  _Stage(this.sites, {required this.drop});

  final SiteRuntime sites;
  final SiteDrop drop;

  @override
  Future<void> prepare() async {}

  @override
  void land({required Commit commit}) => sites.apply(drop, commit: commit);

  @override
  Future<void> follow() async {}
}

void main() {
  test(
    'opted-in backup cookies replace non-secure cookies and keep secure sessions',
    () async {
      final native = MockContainerNative();
      final sites = SiteRuntime()
        ..isolation = Containers(
          engine: ContainerIsolationEngine(containerNative: native),
        );
      final kept = _site('a', cookie: 'old');
      kept.cookies.add(
        Cookie(
          name: 'secure',
          value: 'session',
          domain: 'a.test',
          isSecure: true,
        ),
      );
      sites.applied(SitesLoaded([kept]));
      final replaced = await SiteImport(sites, host: _Host(sites)).replace(
        SitesReplaced(
          scope: ImportScope.replace,
          sites: [_site('a', cookie: 'backup')],
          webspaces: const [],
          selectedWebspaceId: null,
          closed: ArchivesClosed.inTest(),
          restoreCookiesForSiteIds: {SiteId('a')},
        ),
      );
      expect(replaced, isTrue);
      expect(sites.models.single.cookies.map((cookie) => cookie.name), [
        'secure',
        'backup',
      ]);
      expect(
        sites.models.single.pendingContainerCookies.queued?.map((c) => c.name),
        ['backup'],
        reason: 'the container gets the backup\'s cookies with the first '
            'controller; its secure session is already there',
      );
    },
  );

  test("a site the backup carries again keeps its own session, and one it "
      "brings takes the backup's cookies (BACKUP-003)", () async {
    final native = MockContainerNative();
    final sites = SiteRuntime()
      ..isolation = Containers(
        engine: ContainerIsolationEngine(containerNative: native),
      );
    final kept = _site('a', cookie: 'own');
    sites.applied(SitesLoaded([kept, _site('b', cookie: 'dropped')]));
    await native.getOrCreateContainer(kept.containerKey);
    await native.getOrCreateContainer(sites.models.last.containerKey);

    final replaced = await SiteImport(sites, host: _Host(sites)).replace(
      SitesReplaced(
        scope: ImportScope.replace,
        sites: [
          _site('a', cookie: 'backup'),
          _site('c', cookie: 'seed'),
        ],
        webspaces: const [],
        selectedWebspaceId: null,
        closed: ArchivesClosed.inTest(),
      ),
    );

    expect(replaced, isTrue);
    expect(
      {for (final m in sites.models) '${m.siteId}': m.cookies.single.name},
      {'a': 'own', 'c': 'seed'},
    );
    expect(
      {
        for (final m in sites.models)
          '${m.siteId}': m.pendingContainerCookies.queued?.single.name,
      },
      {'a': null, 'c': 'seed'},
      reason: "the site it brings seeds its container with the backup's "
          'cookies; the one it carries keeps its own jar',
    );
    expect(
      native.profiles.keys,
      [kept.containerKey],
      reason:
          'the site it drops takes its container with it, and the one '
          'it carries keeps its own (CONT-010)',
    );
  });

  test("a site the backup carries again keeps the tabs it has, not the "
      "backup's (BACKUP-003)", () async {
    final sites = SiteRuntime()..isolation = Containers(
      engine: ContainerIsolationEngine(containerNative: MockContainerNative()),
    );
    final second = SiteTab(url: 'https://a.test/second');
    sites.applied(SitesLoaded([
      WebViewModel(
        siteId: SiteId('a'),
        initUrl: 'https://a.test/',
        tabs: [SiteTab(id: kPrimaryTabId, url: 'https://a.test/'), second],
        activeTabId: second.id,
      ),
    ]));

    await SiteImport(sites, host: _Host(sites)).replace(
      SitesReplaced(
        scope: ImportScope.replace,
        sites: [_site('a', cookie: 'backup')],
        webspaces: const [],
        selectedWebspaceId: null,
        closed: ArchivesClosed.inTest(),
      ),
    );

    final carried = sites.models.single;
    expect([for (final t in carried.tabs) t.id], [kPrimaryTabId, second.id],
        reason: 'a tab the import dropped would keep its back stack on disk, '
            'and a tab switch under way would find its target gone');
    expect(carried.activeTabId, second.id);
  });
}
