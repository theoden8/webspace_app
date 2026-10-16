import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/controllers/site_deletion.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/l10n/gen/localizations.dart';
import 'package:webspace/services/container_isolation_engine.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/controllers/site_set_commit.dart';

import 'helpers/mock_container_native.dart';
import 'helpers/model_fixture.dart';

/// The page as a delete sees it: its commit applies the change, its frame
/// unmounts the webviews of sites no longer loaded; each lands in the
/// platform's call log, so the order is one list.
final class _Host implements SiteDeletionHost {
  _Host(this.sites, {required this.native});

  final SiteRuntime sites;
  final MockContainerNative native;

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
  Future<void> commitSites(SiteSetChange change) async {
    native.calls.add('commit');
    sites.applied(change);
  }

  @override
  SiteSetStage stageSites(SiteSetChange change) => AppliedStage((commit) {
    native.calls.add('commit');
    sites.apply(change, commit: commit);
  });

  @override
  Future<void> endOfFrame() async {
    native.calls.add('frame');
    for (final m in sites.loaded) {
      expect(native.bound, contains(m.containerKey));
    }
    for (final key in [...native.bound]) {
      if (!sites.loaded.any((m) => m.containerKey == key)) native.unbind(key);
    }
  }
}

void main() {
  test('a delete takes the site off the list, waits for the frame, then '
      'deletes its container (CONT-010, LIR-023)', () async {
    final native = MockContainerNative();
    final a = WebViewModel(siteId: SiteId('a'), initUrl: 'https://a.test');
    final sites = SiteRuntime()
      ..isolation = Containers(
        engine: ContainerIsolationEngine(containerNative: native),
      )
      ..applied(SitesLoaded([a, WebViewModel(siteId: SiteId('b'), initUrl: 'https://b.test')]));
    sites.seed(loaded: [a], shown: a);
    native.bind(a.containerKey);
    await SiteDeletion(sites, host: _Host(sites, native: native)).delete(a);
    expect(sites.models, isNot(contains(a)));
    expect(native.calls, ['commit', 'frame', 'deleteContainer(${a.containerKey})'],
        reason: 'the commit closes the tabs it hosted and the frame unmounts '
            'its webview before its container goes');
    expect(native.profiles, isNot(contains(a.containerKey)));
  });

  test('a site no longer listed is not deleted again', () async {
    final native = MockContainerNative();
    final a = WebViewModel(siteId: SiteId('a'), initUrl: 'https://a.test');
    final sites = SiteRuntime()
      ..isolation = Containers(
        engine: ContainerIsolationEngine(containerNative: native),
      );
    await SiteDeletion(sites, host: _Host(sites, native: native)).delete(a);
    expect(native.calls, isEmpty);
  });
}
