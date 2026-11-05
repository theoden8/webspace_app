import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/controllers/shell_store.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/controllers/site_set_change.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/webspace_model.dart';

import 'helpers/model_fixture.dart';

/// The same three sites, as each launch reads them.
List<WebViewModel> _sites() => [
      for (final id in ['a', 'b', 'c'])
        WebViewModel(siteId: SiteId(id), initUrl: 'https://$id.test'),
    ];

void main() {
  test(
      'WEBSPACE-005: the next launch selects the webspace selected last, and '
      'the drawer shows its sites', () async {
    SharedPreferences.setMockInitialValues({});
    final before = SiteRuntime()..applied(SitesLoaded(_sites()));
    final work = Webspace(name: 'Work', siteIds: [SiteId('a'), SiteId('c')]);
    before.webspaces.addAll([Webspace.all(), work]);
    before.selectedWebspaceId = work.id;
    final store = ShellStore(before);
    await store.saveWebspaces();
    await store.saveSelectedWebspaceId();

    // As startup orders it: the webspaces read, then the sites put on page.
    final after = SiteRuntime();
    await ShellStore(after).loadWebspaces();
    after.applied(SitesLoaded(_sites()));

    expect(after.selectedWebspaceId, work.id);
    expect([for (final i in after.filteredIndices()) after.models[i].siteId],
        [SiteId('a'), SiteId('c')]);
  });
}
