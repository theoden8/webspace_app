import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_teardown_engine.dart';

/// Regression tests for NAV-010: the teardown of the site the user is leaving
/// is best-effort and bounded, so nothing in it can strand the navigation that
/// triggered it.
void main() {
  group('SiteTeardownEngine.quiesceOutgoing', () {
    test('runs the steps in the caller order', () async {
      final order = <String>[];
      final result = await SiteTeardownEngine.quiesceOutgoing(
        superseded: () => false,
        steps: [
          SiteTeardownStep('capture', () async => order.add('capture')),
          SiteTeardownStep('camera', () async => order.add('camera')),
          SiteTeardownStep('media', () async => order.add('media')),
          SiteTeardownStep('pause', () async => order.add('pause')),
        ],
      );
      expect(order, ['capture', 'camera', 'media', 'pause']);
      expect(result.isClean, isTrue);
      expect(result.ran, ['capture', 'camera', 'media', 'pause']);
    });

    test('a throwing step does not cost the steps behind it', () async {
      final order = <String>[];
      final result = await SiteTeardownEngine.quiesceOutgoing(
        superseded: () => false,
        steps: [
          SiteTeardownStep('capture', () async => throw StateError('disk')),
          SiteTeardownStep('pause', () async => order.add('pause')),
        ],
      );
      expect(order, ['pause'],
          reason: 'losing a state capture must not cost the pause');
      expect(result.ran, ['pause']);
      expect(result.errors.keys, ['capture']);
      expect(result.isClean, isFalse);
    });

    test('a step that never answers returns within the budget', () async {
      final never = Completer<void>();
      final reached = <String>[];
      final result = await SiteTeardownEngine.quiesceOutgoing(
        budget: const Duration(milliseconds: 20),
        superseded: () => false,
        steps: [
          SiteTeardownStep('media', () => never.future),
          SiteTeardownStep('pause', () async => reached.add('pause')),
        ],
      ).timeout(const Duration(seconds: 5));
      expect(result.stalledOn, 'media');
      expect(reached, isEmpty);
      expect(result.isClean, isFalse);
    });

    test('a superseding activation stops the remaining steps', () async {
      final order = <String>[];
      var version = 1;
      final result = await SiteTeardownEngine.quiesceOutgoing(
        superseded: () => version != 1,
        steps: [
          SiteTeardownStep('capture', () async {
            order.add('capture');
            version = 2; // a newer _setCurrentIndex landed mid-teardown
          }),
          SiteTeardownStep('pause', () async => order.add('pause')),
        ],
      );
      expect(order, ['capture'],
          reason: 'pausing here would freeze the site the newer switch resumed');
      expect(result.supersededBefore, 'pause');
    });

    test('a stalled step that answers late still respects supersession',
        () async {
      final late = Completer<void>();
      final order = <String>[];
      var version = 1;
      final result = await SiteTeardownEngine.quiesceOutgoing(
        budget: const Duration(milliseconds: 20),
        superseded: () => version != 1,
        steps: [
          SiteTeardownStep('media', () => late.future),
          SiteTeardownStep('pause', () async => order.add('pause')),
        ],
      );
      expect(result.stalledOn, 'media');
      // The caller moved on and a newer activation resumed the site; the
      // abandoned sequence must not pause it when the reply finally lands.
      version = 2;
      late.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(order, isEmpty);
    });
  });
}
