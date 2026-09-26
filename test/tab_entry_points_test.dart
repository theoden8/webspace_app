import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// TAB-005 / TAB-010: where "New tab" and "Duplicate tab" are reached from.
/// The app has two overflow menus (app bar, and the bottom bar when the tab
/// strip is on), and a spec that names "the overflow menu" means both.
/// Structural, because `_WebSpacePageState` is not constructible from a unit
/// test.
void main() {
  late String source;

  setUpAll(() {
    source = File('lib/main.dart').readAsStringSync();
  });

  int count(String needle) =>
      RegExp(RegExp.escape(needle)).allMatches(source).length;

  test('both overflow menus offer New tab and Duplicate tab', () {
    expect(count('value: "newTab"'), 2);
    expect(count('value: "duplicateTab"'), 2);
    expect(count("case 'newTab':"), 2);
    expect(count("case 'duplicateTab':"), 2);
  });

  test('a long press on either refresh button duplicates the tab', () {
    final refresh = RegExp(
      r'tooltip: loading \? loc\.homeStopTooltip : loc\.homeRefreshTooltip,\s*'
      r'onLongPress: _tabsEnabled\s*\?\s*\(\) \{[^}]*_duplicateTab\(',
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

  group('TAB-012: tabs are experimental', () {
    String firstStatement(String signature) {
      final start = source.indexOf(signature);
      expect(start, isNot(-1), reason: '$signature not found');
      final open = source.indexOf('{', start);
      return source.substring(open + 1, source.indexOf(';', open));
    }

    test('the gate is the Site tabs switch', () {
      expect(
        RegExp(r'bool get _tabsEnabled => ExperimentalFeaturesService\.instance'
                r'\s*\.isEnabled\(ExperimentalFeature\.siteTabs\);')
            .hasMatch(source),
        isTrue,
      );
    });

    test('every way into tabs returns first when they are off', () {
      for (final signature in [
        'Future<void> _newTab(',
        'Future<void> _duplicateTab(',
        'Future<bool> _closeChildTabOnBack(',
        'Future<void> _showTabsSheet(',
        'Future<void> _showLinkLongPressMenu(',
      ]) {
        expect(firstStatement(signature), contains('!_tabsEnabled'),
            reason: '$signature must return before doing anything while '
                'tabs are off');
      }
    });

    test('nothing tab-shaped is drawn while they are off', () {
      expect(
        RegExp(r'if \(currentModel != null && _tabsEnabled\)\s*'
                r'_buildTabsButton\(')
            .hasMatch(source),
        isTrue,
        reason: 'the tab count in the app bar',
      );
      final rows = RegExp(
        r'if \(_tabsEnabled\) \.\.\.\[\s*PopupMenuItem<String>\(\s*'
        r'value: "newTab",[\s\S]*?PopupMenuItem<String>\(\s*'
        r'value: "duplicateTab",',
      );
      expect(rows.allMatches(source).length, 2,
          reason: 'New tab and Duplicate tab, in both overflow menus');
      final pills = RegExp(r'(?<!Widget )_tabCountPill\(')
          .allMatches(source)
          .toList();
      expect(pills.length, 3, reason: 'strip chip and both drawer tiles');
      for (final m in pills) {
        final before = source.substring(0, m.start);
        final guard = before.substring(before.lastIndexOf('if ('));
        expect(guard, startsWith('if (_tabsEnabled && '));
      }
    });
  });
}
