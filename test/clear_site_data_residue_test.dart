import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Clear Site Data" wiped the container / cookie jar but left two restorable
/// artefacts behind: the `controller.saveState()` bytes and the encrypted HTML
/// snapshot, both keyed by `siteId` and both replayed on the site's next
/// activation. A page that stashed an identifier in its own URL
/// (`history.pushState(null, '', '/?uid=ABC')`) before the clear was reloaded
/// at that URL afterwards and read itself back, defeating the ETP-022
/// fingerprint reroll the clear had just performed.
///
/// The delete-site and archive-close paths already removed both. This gate
/// keeps the clear path from drifting apart from them again; `_clearSiteData`
/// lives on `_WebSpacePageState`, which no unit test can construct.
void main() {
  late String clearSiteData;

  setUpAll(() {
    final source = File('lib/main.dart').readAsStringSync();
    final start = source.indexOf('Future<void> _clearSiteData(int index) async {');
    if (start < 0) {
      throw StateError('_clearSiteData not found in lib/main.dart');
    }
    // Method bodies at this nesting close on a line of exactly two spaces
    // plus `}`.
    final end = source.indexOf('\n  }\n', start);
    if (end < 0) throw StateError('could not find the end of _clearSiteData');
    clearSiteData = source.substring(start, end);
  });

  test('the clear drops the saved navigation state', () {
    expect(
      clearSiteData.contains('_stateStorage.removeState('),
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

  test('the clear drops the encrypted HTML snapshot', () {
    expect(
      clearSiteData.contains('HtmlCacheService.instance.deleteCache('),
      isTrue,
      reason: 'the cached page body survives a container wipe and is served '
          'to the rebuilt webview',
    );
  });

  test('the removals are unconditional, not inside an engine-mode branch', () {
    // `SiteDataClearEngine.planClear` gates the container / legacy specifics;
    // this residue exists in both modes, and the legacy engine has no
    // container wipe to lean on at all. A statement at the method's own
    // indent sits outside every `if (plan...)` block.
    expect(
      clearSiteData.contains('\n    await _stateStorage.removeState('),
      isTrue,
    );
    expect(
      clearSiteData
          .contains('\n    await HtmlCacheService.instance.deleteCache('),
      isTrue,
    );
  });
}
