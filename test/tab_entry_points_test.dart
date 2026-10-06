import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TAB-005 / TAB-010: where "New tab" and "Duplicate tab" are reached from.
/// The app has two overflow menus (app bar, and the bottom bar when the tab
/// strip is on), and a spec that names "the overflow menu" means both.
/// "Duplicate tab" is a long press on refresh only, never a menu row.
/// Structural, because `_WebSpacePageState` is not constructible from a unit
/// test.
void main() {
  late String source;

  setUpAll(() {
    source = File('lib/main.dart').readAsStringSync();
  });

  int count(String needle) =>
      RegExp(RegExp.escape(needle)).allMatches(source).length;

  test('both overflow menus offer New tab and neither offers Duplicate tab',
      () {
    expect(count('value: "newTab"'), 2);
    expect(count("case 'newTab':"), 2);
    expect(count('value: "duplicateTab"'), 0);
    expect(count("case 'duplicateTab':"), 0);
  });

  test('a long press on either refresh button duplicates the tab', () {
    final refresh = RegExp(
      r'tooltip: loading \? loc\.homeStopTooltip : loc\.homeRefreshTooltip,\s*'
      r'onLongPress: _tabsEnabledAt\(_currentIndex\)\s*\?\s*\(\) \{[^}]*'
      r'_duplicateTab\(',
    );
    expect(refresh.allMatches(source).length, 2);
  });

  test('a duplicate opens parked: it never re-binds the webview', () {
    final start = source.indexOf('Future<void> _duplicateTab(');
    expect(start, isNot(-1));
    final end = source.indexOf('\n  }\n', start);
    final body = source.substring(start, end);
    // The page on screen stays put: no switch, no dispose (TAB-002).
    expect(body.contains('_switchActiveTab('), isFalse);
    expect(body.contains('disposeWebView('), isFalse);
    // Its back stack is written under the copy's own key, never the source's.
    expect(body.contains('saveState(copyKey'), isTrue);
    expect(body.contains('TabLifecycleEngine.insertAfter('), isTrue);
  });

  group('TAB-012 / TAB-013: tabs are experimental and per site', () {
    String firstStatement(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature not found');
      // The body's brace, not a named-parameter list's.
      final open = source.indexOf(RegExp(r'\)\s*(async\s*)?\{'), start);
      final body = source.indexOf('{', open);
      return source.substring(body + 1, source.indexOf(';', body));
    }

    test('the gate is the Site tabs switch and the site\'s own Tabs', () {
      expect(
        RegExp(r'bool get _tabsFeatureEnabled => ExperimentalFeaturesService'
                r'\.instance\s*\.isEnabled\(ExperimentalFeature\.siteTabs\);')
            .hasMatch(source),
        isTrue,
      );
      expect(
        RegExp(r'bool _tabsEnabledFor\(WebViewModel model\) =>\s*'
                r'_tabsFeatureEnabled && model\.effectiveTabsEnabled;')
            .hasMatch(source),
        isTrue,
        reason: 'a kiosk or full-screen site has no tabs',
      );
      expect(
        RegExp(r'bool _tabsEnabledAt\(int\? index\) =>[^;]*'
                r'_tabsEnabledFor\(_webViewModels\[index\]\);')
            .hasMatch(source),
        isTrue,
      );
      expect(RegExp(r'\b_tabsEnabled\b').hasMatch(source), isFalse,
          reason: 'an app-wide gate would let a kiosk site reach its tabs');
    });

    test('every way into tabs returns first when they are off', () {
      for (final (signature, gate) in [
        ('Future<void> _newTab(', '!_tabsEnabledAt(index)'),
        ('Future<void> _duplicateTab(', '!_tabsEnabledAt(index)'),
        ('Future<bool> _closeChildTabOnBack(', '!_tabsEnabledAt(_currentIndex)'),
        ('Future<bool> _returnFromJumpOnBack(', '!_tabsEnabledAt(_currentIndex)'),
        ('Future<void> _showTabsSheet(', '!_tabsEnabledAt(_currentIndex)'),
        ('Future<void> _showLinkLongPressMenu(', '!_tabsEnabledAt(index)'),
        ('Future<void> _openChildTab(', '!_tabsEnabledFor(owner)'),
        ('bool _moveTab(', '!_tabsEnabledAt(index)'),
      ]) {
        expect(firstStatement(signature), contains(gate),
            reason: '$signature must return before doing anything while '
                'the site it acts on has no tabs');
      }
    });

    test('a hosted tab returns links to its owner only while it has tabs',
        () {
      expect(
        RegExp(r'webViewModel\.onReturnToOwner =\s*'
                r'_tabsEnabledFor\(webViewModel\)\s*\?')
            .hasMatch(source),
        isTrue,
        reason: 'an owner without tabs has no tree to take the child',
      );
    });

    test('Back at the start of a tab tries the way back before closing it '
        '(TAB-019, TAB-007)', () {
      expect(RegExp(r'await _backAtTabStart\(\)').allMatches(source),
          hasLength(2),
          reason: 'Android\'s canGoBack path and the attempt-then-compare '
              'path of every other host');
      expect(
          RegExp(r'(?<!Future<bool> )_closeChildTabOnBack\(\)')
              .allMatches(source),
          hasLength(1),
          reason: 'closing is reached only through the funnel');
      final funnel = source.substring(
          source.indexOf('Future<bool> _backAtTabStart('),
          source.indexOf('Future<bool> _returnFromJumpOnBack('));
      expect(funnel.indexOf('_returnFromJumpOnBack()'),
          lessThan(funnel.indexOf('_closeChildTabOnBack()')));
    });

    test('a typed address takes the same steps as a tapped link (LIR-032)',
        () {
      expect(RegExp(r'onUrlSubmitted:').allMatches(source), hasLength(1));
      expect(source, contains('onUrlSubmitted: (url) => _openTypedAddress(model, url),'));
      final start = source.indexOf('Future<void> _openTypedAddress(');
      final body = source.substring(start, source.indexOf('\n  }\n', start));
      expect(body, contains('NavigationDecisionEngine.decideShouldOverrideUrlLoading('));
      expect(body, contains('NavigationDecisionEngine.stepFor('));
      final route = body.indexOf('_routeOutboundLink(model, url, decision, true)');
      expect(route, isNot(-1));
      expect(body.indexOf('_launchNestedForModel('), greaterThan(route),
          reason: 'a nested screen only for what routing leaves');
      expect(File('lib/web_view_model.dart').readAsStringSync(),
          contains('NavigationDecisionEngine.stepFor('),
          reason: 'the page\'s own links take the same step');
    });

    test('work that cannot be dropped waits for the tab gate', () {
      String body(String signature) {
        final start = source.indexOf(signature);
        expect(start, isNot(-1), reason: signature);
        return source.substring(start, source.indexOf('\n  }\n', start));
      }

      expect(
        RegExp(r'while \(_isTabHandling\) \{\s*await _tabGate\.idle\(\);\s*\}\s*'
                r'_isTabHandling = true;')
            .hasMatch(body('Future<T> _withTabGate<T>(')),
        isTrue,
      );
      expect(source, contains('_withTabGate(() => _closeIneligibleHostedTabsHeld(goneSiteId))'));
      expect(body('Future<void> _openLinkInNewTab('), contains('await _withTabGate('),
          reason: 'a background insert must not be lost to a close in flight');
      expect(body('Future<void> _executeOpenInMain('),
          contains('await _withTabGate(() => _switchToOwnerRunTab(model));'));
      expect(body('Future<void> _openTypedAddress('), contains('await _withTabGate('));
      expect(body('Future<void> _dismissKeyboard('), contains('.timeout('),
          reason: 'a stuck page must not keep the list from opening');
      expect(body('Future<void> _showTabsSheet('), contains('_isShowingTabsSheet'));
    });

    test('the tab list leaves out sites without tabs', () {
      final start = source.indexOf('List<TabsSheetSite> _tabsSheetSites() {');
      expect(start, isNot(-1));
      final body = source.substring(start, source.indexOf('\n  }\n', start));
      expect(
        RegExp(r'for \(final i in view\)\s*if \(_tabsEnabledAt\(i\)\)')
            .hasMatch(body),
        isTrue,
      );
      expect(
        RegExp(r'if \(!shown\.contains\(i\) && _tabsEnabledAt\(i\)\)')
            .hasMatch(body),
        isTrue,
        reason: 'a site the webspace hides is listed for TAB-017 only when '
            'it has tabs',
      );
    });

    test('nothing tab-shaped is drawn while they are off', () {
      expect(
        RegExp(r'if \(currentModel != null && '
                r'_tabsEnabledAt\(_currentIndex\)\)\s*_buildTabsButton\(')
            .hasMatch(source),
        isTrue,
        reason: 'the tab count in the app bar',
      );
      final rows = RegExp(
        r'if \(_tabsEnabledAt\(_currentIndex\)\) \.\.\.\[\s*'
        r'PopupMenuItem<String>\(\s*'
        r'value: "newTab",',
      );
      expect(rows.allMatches(source).length, 2,
          reason: 'New tab, in both overflow menus');
      final pills = RegExp(r'(?<!Widget )_tabCountPill\(')
          .allMatches(source)
          .toList();
      expect(pills.length, 3, reason: 'strip chip and both drawer tiles');
      for (final m in pills) {
        final before = source.substring(0, m.start);
        final guard = before.substring(before.lastIndexOf('if ('));
        expect(guard,
            matches(RegExp(r'^if \(_tabsEnabled(At\(index\)|For\(siteModel\)) && ')));
      }
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
      expect(reset, contains('if (_tabsEnabledAt(i)) _webViewModels[i]'));
      expect(reset, contains('await _landOnHomeTab(m);'));
      expect(body('Future<void> _landOnHomeTab('),
          contains('TabLifecycleEngine.homeLanding('));
    });

    test('a cold shortcut launch leaves a site with tabs on its last tab', () {
      // HS-006 sends the launched site home; with tabs, TAB-014 decides.
      expect(
        RegExp(r'if \(!_tabsEnabledAt\(indexToRestore\) && '
                r'm\.currentUrl != m\.initUrl\)')
            .hasMatch(source),
        isTrue,
      );
      expect(
        RegExp(r'coldLaunch &&\s*!_tabsEnabledAt\(resolution\.index\) &&')
            .hasMatch(source),
        isTrue,
      );
    });
  });

  group('TAB-016: a site heading in the Tabs sheet moves the site', () {
    test('offered only where the drawer and the strip reorder', () {
      expect(
          count('onMoveSite: _canReorderCurrentView ? _moveSiteInTabsSheet '
              ': null'),
          1);
    });

    test("the move is the drawer's reorder, not a copy of it", () {
      final start =
          source.indexOf('List<TabsSheetSite>? _moveSiteInTabsSheet(');
      expect(start, isNot(-1));
      final end = source.indexOf('\n  }\n', start);
      final body = source.substring(start, end);
      expect(body.contains('_reorderSite(from, to);'), isTrue);
      // Reordering "All" renumbers every site, so the sheet gets them afresh.
      expect(body.contains('return _tabsSheetSites();'), isTrue);
      expect(body.contains('.insert('), isFalse);
      expect(body.contains('.removeAt('), isFalse);
    });
  });
}
