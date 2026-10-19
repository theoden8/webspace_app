import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/walk/flows.dart';
import 'helpers/walk/frame_values.dart';

void main() {
  tearDown(() => segments = null);

  test(
    'frame snapshots retain their values when source collections change',
    () {
      final tabs = <Object?>['first', 'second'];
      final before = FrameValues([('site', FrameValues(tabs)), null]);
      tabs[0] = 'replacement';
      final after = FrameValues([('site', FrameValues(tabs)), null]);

      expect(
        before,
        FrameValues([
          ('site', FrameValues(['first', 'second'])),
          null,
        ]),
      );
      expect(before, isNot(after));
      expect(
        before.hashCode,
        FrameValues([
          ('site', FrameValues(['first', 'second'])),
          null,
        ]).hashCode,
      );
    },
  );

  test('frame values distinguish order, nulls and embedded separators', () {
    expect(FrameValues(['a,b', 'c']), isNot(FrameValues(['a', 'b,c'])));
    expect(FrameValues(['a', 'b']), isNot(FrameValues(['b', 'a'])));
    expect(FrameValues([null]), isNot(FrameValues(['null'])));
    expect(FrameValues([1]), isNot(FrameValues([1, 2])));
  });

  test('nested segments charge changes to the flow that made them', () {
    final tabs = <Object?>['first'];
    var current = 'old';
    final changes = <({int? flow, Set<Object> keys})>[];
    segments = (
      state: () => {'tabs': FrameValues(tabs), 'current': current},
      changed: (flow, {required keys, required closes}) {
        if (keys.isNotEmpty) changes.add((flow: flow, keys: keys));
      },
    );

    runZoned(() {
      inFlow(() {
        tabs.add('second');
        takeSegment();
        inFlow(() {
          current = 'new';
          takeSegment();
        }, flow: 2);
        tabs.removeLast();
      }, flow: 1);
    }, zoneSpecification: segmentRuns);

    expect(changes.map((change) => change.flow), [1, 2, 1]);
    expect(changes.map((change) => change.keys), [
      {'tabs'},
      {'current'},
      {'tabs'},
    ]);
  });

  test('frame comparisons detect added and removed variables', () {
    final state = <Object, Object>{'kept': 0, 'removed': false};
    final changes = <Set<Object>>[];
    segments = (
      state: () => {...state},
      changed: (flow, {required keys, required closes}) {
        if (keys.isNotEmpty) changes.add(keys);
      },
    );

    runZoned(() {
      state.remove('removed');
      state['added'] = FrameValues([null]);
    }, zoneSpecification: segmentRuns);

    expect(changes, [
      {'removed', 'added'},
    ]);
  });
}
