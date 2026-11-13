import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/reentry_guard.dart';

void main() {
  test('a run that throws still ends, and says so to onChange', () async {
    // The tiles kept their own busy flags and cleared them after a return,
    // so a throw left a row spinning until its screen closed.
    final seen = <bool>[];
    late final ReentryGuard guard;
    guard = ReentryGuard(onChange: () => seen.add(guard.busy));
    await expectLater(
        guard.run(() async => throw StateError('planted')), throwsStateError);
    expect(guard.busy, isFalse);
    expect(seen, [true, false]);
  });

  test('a second run while one is in flight is skipped', () async {
    final guard = ReentryGuard();
    final hold = Completer<void>();
    final first = guard.run(() => hold.future);
    expect(await guard.run(() async {}), isFalse);
    hold.complete();
    expect(await first, isTrue);
  });
}
