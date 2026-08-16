import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/camera_decision_engine.dart';
import 'package:webspace/settings/camera.dart';

/// Drives the real [CameraDecisionEngine] against in-memory storage, the way
/// both the model and the nested screen do — never re-implementing the flow.
class _Host {
  CameraAccessMode mode;
  VirtualCameraSource? source;

  /// Whether the site is the one on screen (main.dart: `_currentIndex == i`).
  bool active;

  /// What the host UI (`resolve`) will return next.
  CameraDecision Function(String origin, CameraAccessMode current)? onResolve;

  int resolveCalls = 0;
  int saveCalls = 0;

  final CameraDecisionEngine engine = CameraDecisionEngine();
  // Lets a test hold the resolve() promise open to exercise coalescing.
  Completer<CameraDecision>? gate;

  _Host({this.mode = CameraAccessMode.ask, this.source, this.active = true});

  Future<CameraDecision> decide(String origin) => engine.decide(
        origin: origin,
        isSiteActive: () => active,
        effectiveMode: mode,
        currentSource: () => source,
        resolve: (o, current) async {
          resolveCalls++;
          if (gate != null) return gate!.future;
          return onResolve!(o, current);
        },
        persist: (m, s) {
          mode = m;
          if (s != null) source = s;
        },
        save: () async => saveCalls++,
      );
}

const _src = VirtualCameraSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'qr.png',
);

void main() {
  group('CameraDecisionEngine', () {
    test('real / block short-circuit without UI or save', () async {
      for (final mode in [CameraAccessMode.real, CameraAccessMode.block]) {
        final host = _Host(mode: mode);
        final d = await host.decide('https://bank.example');
        expect(d.mode, mode);
        expect(host.resolveCalls, 0);
        expect(host.saveCalls, 0);
      }
    });

    test('virtual with a source short-circuits and returns the source', () async {
      final host = _Host(mode: CameraAccessMode.virtual, source: _src);
      final d = await host.decide('https://bank.example');
      expect(d.mode, CameraAccessMode.virtual);
      expect(d.source, same(_src));
      expect(host.resolveCalls, 0);
    });

    test('ask prompts, persists the choice, and saves', () async {
      final host = _Host(mode: CameraAccessMode.ask);
      host.onResolve = (_, __) => const CameraDecision(CameraAccessMode.real);
      final d = await host.decide('https://bank.example');
      expect(d.mode, CameraAccessMode.real);
      expect(host.resolveCalls, 1);
      expect(host.saveCalls, 1);
      expect(host.mode, CameraAccessMode.real); // persisted
    });

    test('picking a virtual source persists mode + source', () async {
      final host = _Host(mode: CameraAccessMode.ask);
      host.onResolve = (_, __) => const CameraDecision(CameraAccessMode.virtual, _src);
      final d = await host.decide('https://bank.example');
      expect(d.mode, CameraAccessMode.virtual);
      expect(d.source, same(_src));
      expect(host.mode, CameraAccessMode.virtual);
      expect(host.source, same(_src));

      // Now that it is settled, a later request short-circuits (no UI).
      host.onResolve = (_, __) => fail('must not prompt once source is set');
      final again = await host.decide('https://bank.example');
      expect(again.source, same(_src));
    });

    test('virtual selected but no source yet re-prompts each request', () async {
      final host = _Host(mode: CameraAccessMode.virtual); // no source
      var calls = 0;
      host.onResolve = (_, current) {
        calls++;
        expect(current, CameraAccessMode.virtual);
        // User cancels the picker: keep virtual, still no source.
        return const CameraDecision(CameraAccessMode.virtual);
      };
      await host.decide('https://bank.example');
      await host.decide('https://bank.example');
      expect(calls, 2,
          reason: 'each request re-offers the picker until a source is set');
      expect(host.source, isNull);
    });

    test('a dismissed ask leaves the site unresolved so it prompts again', () async {
      final host = _Host(mode: CameraAccessMode.ask);
      host.onResolve = (_, __) => const CameraDecision(CameraAccessMode.ask);
      final d = await host.decide('https://bank.example');
      expect(d.mode, CameraAccessMode.ask);
      expect(host.mode, CameraAccessMode.ask);
      // toBridgeJson maps ask -> block, so the request is denied this once.
      expect(d.toBridgeJson()['mode'], 'block');
    });

    test('a burst of ask requests shares one prompt (coalesced)', () async {
      final host = _Host(mode: CameraAccessMode.ask);
      host.gate = Completer<CameraDecision>();
      final a = host.decide('https://bank.example');
      final b = host.decide('https://bank.example');
      final c = host.decide('https://bank.example');
      // All three are queued behind the single open resolve().
      expect(host.resolveCalls, 1);
      host.gate!.complete(const CameraDecision(CameraAccessMode.real));
      final results = await Future.wait([a, b, c]);
      expect(results.every((d) => d.mode == CameraAccessMode.real), isTrue);
      expect(host.resolveCalls, 1,
          reason: 'exactly one prompt for the whole burst');
      expect(host.saveCalls, 1);
    });

    test('a backgrounded site is denied in every mode (CAM-011)', () async {
      for (final mode in CameraAccessMode.values) {
        final host = _Host(
          mode: mode,
          source: mode == CameraAccessMode.virtual ? _src : null,
          active: false,
        );
        host.onResolve = (_, __) => fail('a background site must not prompt');
        final d = await host.decide('https://bank.example');
        expect(d.mode, CameraAccessMode.block, reason: 'stored mode $mode');
        expect(d.source, isNull);
        expect(d.toBridgeJson(), {'mode': 'block'});
        expect(host.resolveCalls, 0);
        expect(host.saveCalls, 0);
        expect(host.mode, mode, reason: 'the stored decision is left intact');
      }
    });

    test('the site decides normally once it is active again', () async {
      final host = _Host(mode: CameraAccessMode.ask, active: false);
      expect((await host.decide('https://bank.example')).mode,
          CameraAccessMode.block);
      expect(host.resolveCalls, 0);
      host.active = true;
      host.onResolve = (_, __) => const CameraDecision(CameraAccessMode.real);
      expect((await host.decide('https://bank.example')).mode,
          CameraAccessMode.real);
      expect(host.resolveCalls, 1);
    });

    test('switching away mid-prompt does not retract the answer', () async {
      final host = _Host(mode: CameraAccessMode.ask);
      host.gate = Completer<CameraDecision>();
      final pending = host.decide('https://bank.example');
      // User answers the popup after the site lost focus.
      host.active = false;
      host.gate!.complete(const CameraDecision(CameraAccessMode.real));
      expect((await pending).mode, CameraAccessMode.real);
      expect(host.mode, CameraAccessMode.real);
      // The next request from the now-backgrounded site is still denied.
      expect((await host.decide('https://bank.example')).mode,
          CameraAccessMode.block);
    });

    test('after a burst settles, the engine can decide again', () async {
      final host = _Host(mode: CameraAccessMode.ask);
      host.gate = Completer<CameraDecision>();
      final first = host.decide('https://bank.example');
      host.gate!.complete(const CameraDecision(CameraAccessMode.block));
      expect((await first).mode, CameraAccessMode.block);
      // Mode is block now -> short-circuits without a new prompt.
      host.gate = null;
      final second = await host.decide('https://bank.example');
      expect(second.mode, CameraAccessMode.block);
      expect(host.resolveCalls, 1);
    });
  });
}
