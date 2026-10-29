import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/site_teardown_engine.dart';

/// A step that records its name in [order] and answers success.
SiteTeardownStep _step(String name, {required List<String> order}) =>
    SiteTeardownStep(name, run: () async {
      order.add(name);
      return true;
    });

/// Regression tests for NAV-010: the teardown of the site the user is leaving
/// is best-effort and bounded, so nothing in it can strand the navigation that
/// triggered it.
void main() {
  group('SiteTeardownEngine.quiesceOutgoing', () {
    test('runs the steps in the caller order', () async {
      final order = <String>[];
      final result = await SiteTeardownEngine.quiesceOutgoing(
        budget: SiteTeardownEngine.defaultBudget,
        superseded: () => false,
        steps: [
          _step('capture', order: order),
          _step('camera', order: order),
          _step('media', order: order),
          _step('pause', order: order),
        ],
      );
      expect(order, ['capture', 'camera', 'media', 'pause']);
      expect(result.isClean, isTrue);
      expect(result.ran, ['capture', 'camera', 'media', 'pause']);
    });

    test('a step that answers failure does not cost the steps behind it',
        () async {
      final order = <String>[];
      final result = await SiteTeardownEngine.quiesceOutgoing(
        budget: SiteTeardownEngine.defaultBudget,
        superseded: () => false,
        steps: [
          SiteTeardownStep('capture', run: () async => false),
          _step('pause', order: order),
        ],
      );
      expect(order, ['pause'],
          reason: 'losing a state capture must not cost the pause');
      expect(result.ran, ['pause']);
      expect(result.failed, ['capture']);
      expect(result.isClean, isFalse);
    });

    test('a step that never answers returns within the budget', () async {
      final never = Completer<bool>();
      final reached = <String>[];
      final result = await SiteTeardownEngine.quiesceOutgoing(
        budget: const Duration(milliseconds: 20),
        superseded: () => false,
        steps: [
          SiteTeardownStep('media', run: () => never.future),
          _step('pause', order: reached),
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
        budget: SiteTeardownEngine.defaultBudget,
        superseded: () => version != 1,
        steps: [
          SiteTeardownStep('capture', run: () async {
            order.add('capture');
            version = 2; // a newer activate landed mid-teardown
            return true;
          }),
          _step('pause', order: order),
        ],
      );
      expect(order, ['capture'],
          reason: 'pausing here would freeze the site the newer switch resumed');
      expect(result.supersededBefore, 'pause');
    });

    test('a stalled step that answers late still respects supersession',
        () async {
      final late = Completer<bool>();
      final order = <String>[];
      var version = 1;
      final result = await SiteTeardownEngine.quiesceOutgoing(
        budget: const Duration(milliseconds: 20),
        superseded: () => version != 1,
        steps: [
          SiteTeardownStep('media', run: () => late.future),
          _step('pause', order: order),
        ],
      );
      expect(result.stalledOn, 'media');
      // The caller moved on and a newer activation resumed the site; the
      // abandoned sequence must not pause it when the reply finally lands.
      version = 2;
      late.complete(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(order, isEmpty);
    });
  });
}
