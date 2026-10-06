import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/tab_return_engine.dart';

/// The way back through jumps the Tabs sheet makes between sites (TAB-019).
void main() {
  List<TabReturn> open(
    List<TabReturn> trail,
    String from,
    String to, {
    String? webspaceId,
  }) {
    final [fs, ft] = from.split('/');
    final [ts, tt] = to.split('/');
    return TabReturnEngine.afterOpen(trail,
        fromSiteId: fs,
        fromTabId: ft,
        toSiteId: ts,
        toTabId: tt,
        webspaceId: webspaceId);
  }

  String? backFrom(List<TabReturn> trail, String at) {
    final [s, t] = at.split('/');
    final back = TabReturnEngine.wayBack(trail, s, t);
    return back == null ? null : '${back.fromSiteId}/${back.fromTabId}';
  }

  test('a jump to another site leads back where it came from', () {
    final trail = open(const [], 'ddg/t1', 'gh/h', webspaceId: 'search');
    expect(backFrom(trail, 'gh/h'), 'ddg/t1');
    expect(trail.single.webspaceId, 'search');
  });

  test('the way back holds only where the jump landed', () {
    final trail = open(const [], 'ddg/t1', 'gh/h');
    expect(backFrom(trail, 'gh/other'), isNull,
        reason: 'another tab of the site the jump went to');
    expect(backFrom(trail, 'ddg/t1'), isNull);
    expect(backFrom(const [], 'gh/h'), isNull);
  });

  test('going back where the last jump came from takes it off', () {
    var trail = open(const [], 'ddg/t1', 'gh/h');
    trail = open(trail, 'gh/h', 'ddg/t1');
    expect(trail, isEmpty);
  });

  test('jumps chain, and Back walks them in reverse', () {
    var trail = open(const [], 'ddg/t1', 'gh/h');
    trail = open(trail, 'gh/h', 'wiki/w');
    expect(backFrom(trail, 'wiki/w'), 'gh/h');
    trail = open(trail, 'wiki/w', 'gh/h');
    expect(backFrom(trail, 'gh/h'), 'ddg/t1',
        reason: 'the earlier jump is still there to go back along');
    trail = open(trail, 'gh/h', 'ddg/t1');
    expect(trail, isEmpty);
  });

  test('a tab of the same site leaves the trail behind', () {
    var trail = open(const [], 'ddg/t1', 'gh/h');
    trail = open(trail, 'gh/h', 'gh/g');
    expect(trail, isEmpty);
  });

  test('a jump from somewhere the trail does not hold starts a new one', () {
    var trail = open(const [], 'ddg/t1', 'gh/h');
    trail = open(trail, 'wiki/w', 'ddg/t2');
    expect(trail, hasLength(1));
    expect(backFrom(trail, 'ddg/t2'), 'wiki/w');
  });

  test('a jump to the tab a stale trail came from is a new jump', () {
    var trail = open(const [], 'ddg/t1', 'gh/h');
    // The screen left gh/h some other way; ddg/t1 is just another tab now.
    trail = open(trail, 'wiki/w', 'ddg/t1');
    expect(backFrom(trail, 'ddg/t1'), 'wiki/w');
  });

  test('the trail keeps the latest jumps', () {
    var trail = const <TabReturn>[];
    var at = 's0/t';
    for (var i = 1; i <= TabReturnEngine.limit + 5; i++) {
      trail = open(trail, at, 's$i/t');
      at = 's$i/t';
    }
    expect(trail, hasLength(TabReturnEngine.limit));
    expect(backFrom(trail, at), 's${TabReturnEngine.limit + 4}/t');
  });
}
