import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TAB-005 / TAB-010: where "New tab" and "Duplicate tab" are reached from.
/// The app has two overflow menus (app bar, and the bottom bar when the tab
/// strip is on), and a spec that names "the overflow menu" means both.
/// "Duplicate tab" is a long press on refresh only, never a menu row.
/// Structural, because `_WebSpacePageState` is not constructible from a unit
/// test; the tab flows themselves are `TabsController`'s.
void main() {
  late String source;
  late String menu;
  late String tabs;
  late String links;

  setUpAll(() {
    source = File('lib/screens/webspace_page.dart').readAsStringSync();
    menu = File('lib/widgets/site_menu.dart').readAsStringSync();
    tabs = File('lib/controllers/tabs_controller.dart').readAsStringSync();
    links = File('lib/controllers/link_controller.dart').readAsStringSync();
  });

  int count(String needle) =>
      RegExp(RegExp.escape(needle)).allMatches(source).length;

  test('both overflow menus offer New tab and neither offers Duplicate tab',
      () {
    expect(count('_siteMenu(SiteMenuPlacement.appBar)'), 1);
    expect(count('_siteMenu(SiteMenuPlacement.bottomBar)'), 1);
    expect('SiteMenuAction.newTab =>'.allMatches(menu), hasLength(1));
    expect(menu, isNot(contains('SiteMenuAction.duplicateTab')));
    expect(source, isNot(contains('SiteMenuAction.duplicateTab')));
  });

  test('a long press on the menus\' refresh button duplicates the tab', () {
    final refresh = RegExp(
      r'tooltip: loading \? loc\.homeStopTooltip : loc\.homeRefreshTooltip,\s*'
      r'onLongPress:\s*duplicateTab == null \? null : \(\) => close\(duplicateTab\),',
    );
    expect(refresh.allMatches(menu).length, 1);
    final duplicate = RegExp(
      r'duplicateTab: _tabs\.enabledAt\(_sites\.current\)\s*\?\s*\(\) \{[^}]*'
      r'_tabs\.duplicateTab\(',
    );
    expect(duplicate.allMatches(source).length, 1);
  });

  test('a duplicate opens parked: it never re-binds the webview', () {
    final start = tabs.indexOf('Future<void> duplicateTab(');
    expect(start, isNot(-1));
    final end = tabs.indexOf('\n  }\n', start);
    final body = tabs.substring(start, end);
    // The page on screen stays put: no switch, no dispose (TAB-002).
    expect(body.contains('switchActiveTab('), isFalse);
    expect(body.contains('disposeWebView('), isFalse);
    // Its back stack is written under the copy's own key, never the source's.
    expect(body.contains('saveState(copyKey'), isTrue);
    expect(body.contains('TabLifecycleEngine.insertAfter('), isTrue);
  });

  group('TAB-012 / TAB-013: tabs are experimental and per site', () {
    String firstStatement(String source, {required String signature}) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature not found');
      // The body's brace, not a named-parameter list's.
      final open = source.indexOf(RegExp(r'\)\s*(async\s*)?\{'), start);
      final body = source.indexOf('{', open);
      return source.substring(body + 1, source.indexOf(';', body));
    }

    test('the gate is the Site tabs switch and the site\'s own Tabs', () {
      expect(
        RegExp(r'bool get featureEnabled => ExperimentalFeaturesService'
                r'\.instance\s*\.isEnabled\(ExperimentalFeature\.siteTabs\);')
            .hasMatch(tabs),
        isTrue,
      );
      expect(
        RegExp(r'bool enabledFor\(WebViewModel model\) =>\s*'
                r'featureEnabled && model\.effectiveTabsEnabled;')
            .hasMatch(tabs),
        isTrue,
        reason: 'a kiosk or full-screen site has no tabs',
      );
      expect(
        RegExp(r'bool enabledAt\(int\? index\) =>[^;]*'
                r'enabledFor\(_sites\.models\[index\]\);')
            .hasMatch(tabs),
        isTrue,
      );
      expect(RegExp(r'\b_tabsEnabled\b').hasMatch(source), isFalse,
          reason: 'an app-wide gate would let a kiosk site reach its tabs');
      expect(RegExp(r'\bbool get enabled\b').hasMatch(tabs), isFalse,
          reason: 'an app-wide gate would let a kiosk site reach its tabs');
    });

    test('every way into tabs returns first when they are off', () {
      for (final (src, signature, gate) in [
        (tabs, 'Future<void> newTab(', '!enabledAt(index)'),
        (tabs, 'Future<void> duplicateTab(', '!enabledAt(index)'),
        (tabs, 'Future<bool> _closeChildTabOnBack(', '!enabledAt(_sites.current)'),
        (tabs, 'Future<bool> _returnFromJumpOnBack(', '!enabledAt(_sites.current)'),
        (source, 'Future<void> _showTabsSheet(', '!_tabs.enabledAt(_sites.current)'),
        (source, 'Future<void> _showLinkLongPressMenu(', '!_tabs.enabledAt(index)'),
        (tabs, 'Future<void> openChildTab(', '!enabledFor(owner)'),
        (tabs, 'bool moveTab(', '!enabledAt(index)'),
      ]) {
        expect(firstStatement(src, signature: signature), contains(gate),
            reason: '$signature must return before doing anything while '
                'the site it acts on has no tabs');
      }
    });

    test('a hosted tab returns links to its owner only while it has tabs',
        () {
      expect(
        RegExp(r'site\.onReturnToOwner =\s*'
                r'_tabs\.enabledFor\(site\)\s*\?')
            .hasMatch(source),
        isTrue,
        reason: 'an owner without tabs has no tree to take the child',
      );
    });

    test('Back at the start of a tab tries the way back before closing it '
        '(TAB-019, TAB-007)', () {
      expect(
          RegExp(r'await _host\.backAtTabStart\(\)').allMatches(
              File('lib/controllers/back_gesture_controller.dart')
                  .readAsStringSync()),
          hasLength(2),
          reason: 'Android\'s canGoBack path and the attempt-then-compare '
              'path of every other host');
      expect(source,
          contains('Future<bool> backAtTabStart() => _s._tabs.backAtTabStart();'));
      expect(
          RegExp(r'(?<!Future<bool> )_closeChildTabOnBack\(\)')
              .allMatches(tabs),
          hasLength(1),
          reason: 'closing is reached only through the funnel');
      final funnel = tabs.substring(
          tabs.indexOf('Future<bool> backAtTabStart('),
          tabs.indexOf('Future<bool> _returnFromJumpOnBack('));
      expect(funnel.indexOf('_returnFromJumpOnBack()'),
          lessThan(funnel.indexOf('_closeChildTabOnBack()')));
    });

    test('a typed address takes the same steps as a tapped link (LIR-032)',
        () {
      expect(RegExp(r'onUrlSubmitted:').allMatches(source), hasLength(1));
      expect(
          source,
          contains(
              'onUrlSubmitted: (url) => _links.openTypedAddress(model, url: url),'));
      final start = links.indexOf('Future<void> openTypedAddress(');
      final body = links.substring(start, links.indexOf('\n  }\n', start));
      expect(body, contains('NavigationDecisionEngine.decideShouldOverrideUrlLoading('));
      expect(body, contains('NavigationDecisionEngine.stepFor('));
      final route = body.indexOf(
          'routeOutbound(model, url: url, decision: decision, hadGesture: true)');
      expect(route, isNot(-1));
      expect(body.indexOf('_host.launchNestedFor('), greaterThan(route),
          reason: 'a nested screen only for what routing leaves');
      expect(File('lib/web_view_model.dart').readAsStringSync(),
          contains('NavigationDecisionEngine.stepFor('),
          reason: 'the page\'s own links take the same step');
    });

    test('work that cannot be dropped waits for the tab gate', () {
      String body(String signature, {String? src}) {
        final from = src ?? source;
        final start = from.indexOf(signature);
        expect(start, isNot(-1), reason: signature);
        return from.substring(start, from.indexOf('\n  }\n', start));
      }

      expect(tabs, contains('_gate.runWhenIdle(() => _closeIneligibleHostedTabsHeld(goneSiteId))'));
      expect(body('Future<void> openLinkInNewTab(', src: tabs),
          contains('await _gate.runWhenIdle('),
          reason: 'a background insert must not be lost to a close in flight');
      expect(body('Future<void> _executeOpenInMain(', src: links),
          contains('await _tabs.runWhenIdle(() => _tabs.switchToOwnerRunTab(model));'));
      expect(body('Future<void> openTypedAddress(', src: links),
          contains('await _tabs.runWhenIdle('));
      expect(body('Future<void> _dismissKeyboard('), contains('.timeout('),
          reason: 'a stuck page must not keep the list from opening');
      expect(body('Future<void> _showTabsSheet('), contains('_isShowingTabsSheet'));
    });

    test('the tab list leaves out sites without tabs', () {
      final start = source.indexOf('List<TabsSheetSite> _tabsSheetSites() {');
      expect(start, isNot(-1));
      final body = source.substring(start, source.indexOf('\n  }\n', start));
      expect(
        RegExp(r'for \(final i in view\)\s*if \(_tabs\.enabledAt\(i\)\)')
            .hasMatch(body),
        isTrue,
      );
      expect(
        RegExp(r'if \(!shown\.contains\(i\) && _tabs\.enabledAt\(i\)\)')
            .hasMatch(body),
        isTrue,
        reason: 'a site the webspace hides is listed for TAB-017 only when '
            'it has tabs',
      );
    });

    test('nothing tab-shaped is drawn while they are off', () {
      expect(
        RegExp(r'if \(currentModel != null && '
                r'_tabs\.enabledAt\(_sites\.current\)\)\s*TabCountButton\(')
            .hasMatch(source),
        isTrue,
        reason: 'the tab count in the app bar',
      );
      expect(
        menu,
        contains('SiteMenuAction.newTab =>\n'
            '          state.tabsOn ? (Icons.add, loc.tabsNewTab) : null,'),
        reason: 'New tab, in the overflow menus',
      );
      expect(source, contains('tabsOn: _tabs.enabledAt(_sites.current),'),
          reason: 'the menus read tabs as the site on screen has them');
void guarded(String src,
    {required int count, required RegExp guard, required String reason}) {
  final pills = 'TabCountPill('.allMatches(src).toList();
  expect(pills.length, count, reason: reason);
  for (final m in pills) {
    final before = src.substring(0, m.start);
    expect(before.substring(before.lastIndexOf('if (')), matches(guard));
  }
}

      guarded(File('lib/widgets/site_tab_strip.dart').readAsStringSync(),
          count: 1,
          guard: RegExp(r'^if \(showsTabCount\(site\) && '),
          reason: 'the strip chip');
      expect(source, contains('showsTabCount: _tabs.enabledFor,'),
          reason: 'the strip chip counts tabs only where the site has them');
      expect(File('lib/widgets/site_drawer.dart').readAsStringSync(),
          matches(RegExp(r'showTabCount:\s*showsTabCount\(index\) &&')),
          reason: 'the drawer tile');
      expect(source, contains('showsTabCount: _tabs.enabledAt,'),
          reason: 'the drawer counts tabs only where the site has them');
      guarded(File('lib/widgets/site_grid_tile.dart').readAsStringSync(),
          count: 2,
          guard: RegExp(r'^if \(showTabCount\)'),
          reason: 'both drawer tile layouts');
    });
  });

  group('TAB-014: shortcut and reopen land a site with tabs', () {
    String body(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature not found');
      return source.substring(start, source.indexOf('\n  }\n', start));
    }

    test('an always-home site with tabs lands on a home tab, not in place', () {
      final reset = body('Future<void> _resetAlwaysOpenHomeOnShortcut(');
      expect(reset, contains('if (_tabs.enabledAt(i)) _sites.models[i]'));
      expect(reset, contains('await _tabs.landOnHomeTab(m);'));
      final land = tabs.substring(tabs.indexOf('Future<void> landOnHomeTab('));
      expect(land.substring(0, land.indexOf('\n  }\n')),
          contains('TabLifecycleEngine.homeLanding('));
    });

    test('a cold shortcut launch leaves a site with tabs on its last tab', () {
      // HS-006 sends the launched site home; with tabs, TAB-014 decides.
      final shortcuts =
          File('lib/controllers/shortcut_controller.dart').readAsStringSync();
      expect(
        RegExp(r'if \(!_host\.tabsEnabledAt\(index\) && '
                r'm\.currentUrl != m\.initUrl\)')
            .hasMatch(shortcuts),
        isTrue,
      );
      expect(
        RegExp(r'coldLaunch &&\s*!_host\.tabsEnabledAt\(index\) &&')
            .hasMatch(shortcuts),
        isTrue,
      );
    });
  });

  group('TAB-016: a site heading in the Tabs sheet moves the site', () {
    test('offered only where the drawer and the strip reorder', () {
      expect(
          count('onMoveSite: _webspaces.canReorderView ? _moveSiteInTabsSheet '
              ': null'),
          1);
    });

    test("the move is the drawer's reorder, not a copy of it", () {
      final start =
          source.indexOf('List<TabsSheetSite>? _moveSiteInTabsSheet(');
      expect(start, isNot(-1));
      final end = source.indexOf('\n  }\n', start);
      final body = source.substring(start, end);
      expect(body.contains('_webspaces.reorderSite(from, newListIndex: to);'),
          isTrue);
      // Reordering "All" renumbers every site, so the sheet gets them afresh.
      expect(body.contains('return _tabsSheetSites();'), isTrue);
      expect(body.contains('.insert('), isFalse);
      expect(body.contains('.removeAt('), isFalse);
    });
  });
}
