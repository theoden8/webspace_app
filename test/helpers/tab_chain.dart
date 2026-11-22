import 'package:webspace/services/site_tab.dart';
import 'package:webspace/web_view_model.dart';

import 'model_fixture.dart';

/// A site with [urls] as tabs. The first is the active one; every later tab is
/// a child of the one before it, so the fixture is a chain as deep as [urls].
WebViewModel siteWithChain(String name, {required List<String> urls}) {
  final m = WebViewModel(initUrl: urls.first, name: name);
  var parent = m.activeTabId;
  for (final url in urls.skip(1)) {
    final t = SiteTab(id: TabId('tab${m.tabs.length}'), url: url, parentId: parent);
    m.setTabs([...m.tabs, t]);
    parent = t.id;
  }
  return m;
}
