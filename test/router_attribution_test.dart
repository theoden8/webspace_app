import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/proxy_router_engine.dart';
import 'package:webspace/services/router_attribution.dart';
import 'package:webspace/settings/site_ids.dart';

import 'helpers/fake_auth_caches.dart';

RouterIdentity site(String id) => RouterIdentity.ofSite(SiteId(id));

void main() {
  late Map<String, String> observed;
  late List<Set<RouterIdentity>> failures;

  setUp(() {
    observed = {};
    failures = [];
  });

  RouterAttribution checksOver(
    FakeAuthCaches device, {
    Future<void>? queuedAfter,
  }) => RouterAttribution(
    probe: device.probe,
    observed: () async => Map.of(observed),
    onFailed: failures.add,
    queuedAfter: queuedAfter,
  );

  FakeAuthCaches honest() => FakeAuthCaches(
    record: ({required nonce, required identity}) => observed[nonce] = identity,
  );

  group('the proof (PROXY-015)', () {
    test('holds where every profile presents its own credential', () async {
      final device = honest();
      final checks = checksOver(device);
      expect(await checks.prove([site('a'), site('b')]), isTrue);
      expect(await checks.attributed(site('a')), isTrue);
      expect(await checks.attributed(site('b')), isTrue);
    });

    test(
      'fails on one shared cache, which only checks in turn can see',
      () async {
        // Side by side, both probes start cold and each answers with its own
        // credential: a device with one cache for every profile passes. Only
        // the second probe starting after the first ended carries the first's.
        final device = FakeAuthCaches.shared(
          record: ({required nonce, required identity}) =>
              observed[nonce] = identity,
        );
        final checks = checksOver(device);
        expect(await checks.prove([site('a'), site('b')]), isFalse);
        expect(device.mostAtOnce, 1, reason: 'the proof checks one at a time');
        expect(
          await checks.attributed(site('a')),
          isFalse,
          reason: 'nothing is answered once the proof failed',
        );
      },
    );

    test('checks only the first two; the rest after it holds', () async {
      final device = honest();
      final gate = Completer<void>();
      device.gates[site('c')] = gate;
      final checks = checksOver(device);
      expect(
        await checks.prove([site('a'), site('b'), site('c'), site('d')]),
        isTrue,
      );
      expect(device.started.take(2), [site('a'), site('b')]);
      expect(await checks.attributed(site('d')), isTrue);
      var cAnswered = false;
      unawaited(checks.attributed(site('c')).then((_) => cAnswered = true));
      await pumpEventQueue();
      expect(cAnswered, isFalse, reason: "c's check has not ended");
      gate.complete();
      await pumpEventQueue();
      expect(cAnswered, isTrue);
    });

    test('a question asked before the proof ends waits for it', () async {
      final device = honest();
      final gate = Completer<void>();
      device.gates[site('b')] = gate;
      final checks = checksOver(device);
      final proof = checks.prove([site('a'), site('b'), site('c')]);
      final answer = <bool>[];
      unawaited(checks.attributed(site('c')).then(answer.add));
      await pumpEventQueue();
      expect(answer, isEmpty);
      expect(
        device.started,
        isNot(contains(site('c'))),
        reason: 'nothing outside the proof runs before it holds',
      );
      gate.complete();
      expect(await proof, isTrue);
      await pumpEventQueue();
      expect(answer, [true]);
    });

    test('ending the run answers every waiting question no', () async {
      final device = honest();
      device.gates[site('a')] = Completer<void>();
      final checks = checksOver(device);
      unawaited(checks.prove([site('a'), site('b')]));
      final answer = checks.attributed(site('b'));
      checks.end();
      expect(await answer, isFalse);
    });
  });

  group('around the launch (PROXY-015)', () {
    test('the launched site leads the proof', () async {
      final device = honest();
      final checks = checksOver(device);
      expect(
        await checks.prove([site('a'), site('b'), site('c')], first: site('c')),
        isTrue,
      );
      expect(device.started.take(2), [site('c'), site('a')]);
      expect(await checks.attributed(site('b')), isTrue);
    });

    test('a launched site the proof cannot check leaves its order', () async {
      final device = honest();
      final checks = checksOver(device);
      expect(
        await checks.prove([site('a'), site('b')], first: RouterIdentity.shared),
        isTrue,
      );
      expect(device.started, [site('a'), site('b')]);
    });

    test(
      'queued checks wait for the launched page; a site that asks does not',
      () async {
        final device = honest();
        final settled = Completer<void>();
        final checks = checksOver(device, queuedAfter: settled.future);
        expect(
          await checks.prove([site('a'), site('b'), site('c'), site('d')]),
          isTrue,
        );
        await pumpEventQueue();
        expect(device.started, [site('a'), site('b')]);
        expect(await checks.attributed(site('d')), isTrue);
        expect(device.started, isNot(contains(site('c'))));

        settled.complete();
        await pumpEventQueue();
        expect(device.started, contains(site('c')));
        expect(
          device.started.where((s) => s == site('d')),
          hasLength(1),
          reason: 'a site checked on demand leaves the queue',
        );
      },
    );
  });

  group('after the proof', () {
    test('queued checks run at most four at once', () async {
      final device = honest();
      final checks = checksOver(device);
      final ids = [for (var i = 0; i < 10; i++) site('s$i')];
      expect(await checks.prove(ids), isTrue);
      await pumpEventQueue();
      expect(device.mostAtOnce, RouterAttribution.concurrency);
      for (final id in ids) {
        expect(await checks.attributed(id), isTrue);
      }
      expect(device.started.toSet(), ids.toSet());
      expect(
        device.started,
        hasLength(ids.length),
        reason: 'each identity is checked once',
      );
    });

    test(
      'a site waiting on its check runs it before the queue reaches it',
      () async {
        final device = honest();
        final gates = {
          for (var i = 0; i < 4; i++) site('busy$i'): Completer<void>(),
        };
        device.gates.addAll(gates);
        final checks = checksOver(device);
        expect(
          await checks.prove([
            site('a'),
            site('b'),
            ...gates.keys,
            site('wanted'),
          ]),
          isTrue,
        );
        await pumpEventQueue();
        expect(
          device.started,
          isNot(contains(site('wanted'))),
          reason: 'every slot is busy',
        );
        expect(await checks.attributed(site('wanted')), isTrue);
        for (final g in gates.values) {
          g.complete();
        }
      },
    );

    test('a probe that reports nothing is asked once more', () async {
      final device = honest()..silent[site('a')] = 1;
      final checks = checksOver(device);
      expect(await checks.prove([site('a'), site('b')]), isTrue);
      final twice = honest()..silent[site('a')] = 2;
      expect(await checksOver(twice).prove([site('a'), site('b')]), isFalse);
    });

    test(
      'a late check carrying another credential fails both, verified or not',
      () async {
        // c's profile caches with a's: a pairing the proof of a and b cannot
        // see. c's probe then carries a's credential, so neither a nor c can be
        // told apart any longer.
        final device = FakeAuthCaches(
          record: ({required nonce, required identity}) =>
              observed[nonce] = identity,
          profileOf: (identity) => identity == site('c') ? site('a') : identity,
        );
        final checks = checksOver(device);
        expect(await checks.prove([site('a'), site('b'), site('c')]), isTrue);
        expect(await checks.attributed(site('c')), isFalse);
        expect(await checks.attributed(site('a')), isFalse);
        expect(await checks.attributed(site('b')), isTrue);
        expect(failures.last, {site('a'), site('c')});
      },
    );

    test(
      'a failed proof reports nothing to stop: the router stands down',
      () async {
        final device = FakeAuthCaches.shared(
          record: ({required nonce, required identity}) =>
              observed[nonce] = identity,
        );
        expect(await checksOver(device).prove([site('a'), site('b')]), isFalse);
        expect(failures, isEmpty);
      },
    );

    test('the shared identity is checked like any other', () async {
      final device = honest();
      final checks = checksOver(device);
      expect(await checks.prove([site('a')]), isTrue);
      checks.enqueue([RouterIdentity.shared]);
      expect(await checks.attributed(RouterIdentity.shared), isTrue);
      expect(device.started, contains(RouterIdentity.shared));
    });
  });
}
