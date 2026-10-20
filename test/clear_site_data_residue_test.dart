import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Clear Site Data" wiped the container / cookie jar but left restorable
/// artefacts behind: the `controller.saveState()` bytes, keyed by `siteId` and
/// replayed on the site's next activation, and, under the shared jar, the
/// engine's HTTP cache, which no container scopes there and which a
/// cache-first load serves. A page that stashed an identifier in its own URL
/// (`history.pushState(null, '', '/?uid=ABC')`) before the clear was reloaded
/// at that URL afterwards and read itself back, defeating the ETP-022
/// fingerprint reroll the clear had just performed.
///
/// This gate keeps the clear path from drifting apart from the delete-site
/// and archive-close paths again; `_clearSiteData` lives on
/// `_WebSpacePageState`, which no unit test can construct.
void main() {
  late String clearSiteData;

  setUpAll(() {
    final source = File('lib/screens/webspace_page.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _clearSiteData(WebViewModel model) async {');
    if (start < 0) {
      throw StateError('_clearSiteData not found in lib/screens/webspace_page.dart');
    }
    // Method bodies at this nesting close on a line of exactly two spaces
    // plus `}`.
    final end = source.indexOf('\n  }\n', start);
    if (end < 0) throw StateError('could not find the end of _clearSiteData');
    clearSiteData = source.substring(start, end);
  });

  test('the clear drops the saved navigation state of every tab', () {
    // Site-wide, not `removeState(<one key>)`: state is keyed per tab now, so
    // dropping only the active tab's bytes would leave every parked tab of the
    // site holding its pre-clear URL, ready to be restored on the next switch.
    expect(
      clearSiteData.contains('_stateStorage.removeStatesForSite('),
      isTrue,
      reason: 'restored saveState() bytes carry the pre-clear URL, which is '
          'the page\'s own identifier when it put one there',
    );
  });

  test('the clear drops the pending navigation-state capture', () {
    expect(
      clearSiteData.contains('_navStateDebouncer.cancel('),
      isTrue,
      reason: 'a debounced capture scheduled before the clear would write the '
          'pre-clear state straight back',
    );
  });

  test('under the shared jar the clear drops the engine cache too', () {
    final legacy = clearSiteData.substring(clearSiteData.indexOf('case SharedJar():'));
    expect(
      legacy.contains('await clearEngineCache();'),
      isTrue,
      reason: 'no container scopes the HTTP cache there, and a cache-first '
          'load would serve the page body from before the clear',
    );
  });

  test('the removals are unconditional, not inside an engine-mode branch', () {
    // The switch on the isolation holds the container / legacy specifics;
    // this residue exists in both modes. A statement at the method's own
    // indent sits outside every case of it.
    expect(
      clearSiteData.contains('\n    await _stateStorage.removeStatesForSite('),
      isTrue,
    );
  });
}
