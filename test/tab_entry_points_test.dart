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
      r'onLongPress: \(\) \{[^}]*_duplicateTab\(',
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
}
