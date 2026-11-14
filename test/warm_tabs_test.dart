import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_js.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/services/site_tab.dart';
import 'package:webspace/services/site_unload_engine.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/services/warm_tabs.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/fake_webview_controller.dart';
import 'helpers/model_fixture.dart';

const _frame = Commit.environment(Environment.frame);

/// A site whose tabs are [ids], each used [ago] minutes before now in the
/// order given, the first its own and the rest as [hosted] says.
WebViewModel _site(
  String name, {
  required List<String> ids,
  Set<String> hosted = const {},
}) {
  final m = WebViewModel(initUrl: 'https://$name.example/', name: name);
  final now = DateTime(2026, 11, 12, 12);
  m.setTabs([
    for (final (i, id) in ids.indexed)
      SiteTab(
        id: TabId(id),
        url: 'https://$name.example/$id',
        lastActiveAt: now.subtract(Duration(minutes: ids.length - i)),
        hostSiteId: hosted.contains(id) ? SiteId('host') : null,
      ),
  ]);
  m.setActiveTab(TabId(ids.first));
  return m;
}

/// Keeps [tab]'s view of [m] warm, a fake standing for its webview.
FakeWebViewController _warm(WebViewModel m, {required String tab}) {
  final view = FakeWebViewController();
  m.controller = view;
  m.views.keepShown(tab: TabId(tab), commit: _frame);
  return view;
}

void main() {
  group('TAB-023: the warm view a slot lets go of', () {
    test('is the one used longest ago', () {
      final m = _site('a', ids: ['t0', 't1', 't2']);
      expect(
        leastRecentlyUsed([TabId('t1'), TabId('t2')], tabs: m.tabs, inUse: null),
        TabId('t1'),
      );
    });

    test('is never the tab shown until now while another is warm', () {
      final m = _site('a', ids: ['t0', 't1']);
      // t0 was made active long ago and shown since: it is the newest.
      expect(
        leastRecentlyUsed([TabId('t0'), TabId('t1')], tabs: m.tabs, inUse: TabId('t0')),
        TabId('t1'),
      );
    });

    test('is none where the limit lets every view stay', () {
      final m = _site('a', ids: ['t0']);
      expect(leastRecentlyUsed([null], tabs: m.tabs, inUse: null), isNull);
    });
  });

  group('TAB-024: the order warm views go in', () {
    test("other sites' warm views first, hosted before own, then the "
        "on-screen site's, least recently used first within each", () {
      final shown = _site('shown', ids: ['s0', 's1', 's2'], hosted: {'s2'});
      final other = _site('other', ids: ['o0', 'o1', 'o2'], hosted: {'o2'});
      final order = SiteUnloadEngine.inDropOrder(
        [
          (shown, TabId('s1')),
          (shown, TabId('s2')),
          (other, TabId('o1')),
          (other, TabId('o2')),
        ],
        onScreen: shown,
      );
      expect([for (final (_, t) in order) '$t'], ['o2', 'o1', 's2', 's1']);
    });

    test('the cap drops as many warm views as the views exceed it, none '
        'while they fit', () {
      final a = _site('a', ids: ['a0', 'a1', 'a2']);
      final b = _site('b', ids: ['b0', 'b1']);
      _warm(a, tab: 'a1');
      _warm(a, tab: 'a2');
      _warm(b, tab: 'b1');
      // Two sites and three warm views: five views.
      expect(
        SiteUnloadEngine.warmToDropForCap(target: a, sites: [a, b], maxLoaded: 5),
        isEmpty,
      );
      final dropped =
          SiteUnloadEngine.warmToDropForCap(target: a, sites: [a, b], maxLoaded: 3);
      expect([for (final (s, t) in dropped) '${s.name}.$t'], ['b.b1', 'a.a1']);
    });
  });

  group("TAB-023: a site's views move only through SiteViews", () {
    test('the shown view kept warm leaves nothing shown, and shows again whole',
        () {
      final m = _site('a', ids: ['t0', 't1']);
      final view = FakeWebViewController();
      m.controller = view;
      expect(m.views.keepShown(tab: TabId('t0'), commit: _frame), same(view));
      expect(m.controller, isNull);
      expect(m.warmViews.keys, [TabId('t0')]);
      expect(m.views.show(tab: TabId('t0'), commit: _frame), same(view));
      expect(m.controller, same(view));
      expect(m.warmViews, isEmpty);
    });

    test('letting go of all takes every view and waits for each', () {
      final m = _site('a', ids: ['t0', 't1', 't2']);
      _warm(m, tab: 't1');
      _warm(m, tab: 't2');
      final shown = FakeWebViewController();
      m.controller = shown;
      final leaving = m.views.letGoOfAll(shown: shown, commit: _frame);
      expect(leaving, isNotNull);
      expect(m.controller, isNull);
      expect(m.warmViews, isEmpty);
    });

    test('a dropped warm view is still waited for by the site\'s leave', () {
      final m = _site('a', ids: ['t0', 't1']);
      final gone = _warm(m, tab: 't1');
      m.views.drop(tab: TabId('t1'), commit: _frame);
      expect(m.warmViews, isEmpty);
      // Nothing shown, one departing: the leave waits for that one.
      expect(m.views.letGoOfAll(shown: null, commit: _frame), same(gone));
    });
  });

  test('TAB-025: a view going warm stops its capture and media, then pauses',
      () async {
    final m = _site('a', ids: ['t0', 't1']);
    final view = FakeWebViewController();
    m.controller = view;
    m.tabBinding.bind(TabId('t0'), commit: _frame);
    m.keepShownWarm(tab: TabId('t0'), commit: _frame);
    await pumpEventQueue();
    expect(view.evaluated, [stopCaptureScript, PageJs.mediaPause.script]);
    expect(view.calls.last, 'pause');
    expect(m.tabBinding.built, isNull);
  });

  test("TAB-027: an unload of a site takes every view of its slot, warm "
      'ones with the shown one', () {
    final m = _site('a', ids: ['t0', 't1', 't2'], hosted: {'t1', 't2'});
    _warm(m, tab: 't1');
    _warm(m, tab: 't2');
    m.controller = FakeWebViewController();
    m.disposeWebView(commit: const Commit.environment(Environment.letGo));
    expect(m.controller, isNull);
    expect(m.warmViews, isEmpty);
  });

  group('TAB-028: a warm view goes with no capture', () {
    // The capture ran as its tab stopped being active, in the switch's
    // tCap and tCapSave before tRebind kept it warm; the tab schedules
    // replay that order against activation.tla.
    test('over the limit, closed, or by the cap', () async {
      final m = _site('a', ids: ['t0', 't1']);
      final view = _warm(m, tab: 't1');
      m.dropWarm(tab: TabId('t1'), commit: _frame);
      await pumpEventQueue();
      expect(view.calls, isNot(contains('saveState')));
    });

    test('with its slot', () async {
      final m = _site('a', ids: ['t0', 't1', 't2']);
      final warm = [_warm(m, tab: 't1'), _warm(m, tab: 't2')];
      m.controller = FakeWebViewController();
      m.disposeWebView(commit: const Commit.environment(Environment.letGo));
      await pumpEventQueue();
      for (final view in warm) {
        expect(view.calls, isNot(contains('saveState')));
      }
    });
  });

  test('the app keeps three warm tabs a slot, and two more hosted', () {
    expect(kWarmLimits, (own: 3, hosted: 2));
  });
}
