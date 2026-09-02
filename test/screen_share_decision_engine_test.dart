import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/screen_share_decision_engine.dart';
import 'package:webspace/settings/screen_share.dart';

/// Drives the real [ScreenShareDecisionEngine] against in-memory storage, the
/// way both the model and the nested screen do — never re-implementing the
/// flow.
class _Host {
  ScreenShareMode mode;
  VirtualScreenSource? source;

  /// What the host UI (`resolve`) will return next.
  ScreenShareDecision Function(String origin, ScreenShareMode current)?
      onResolve;

  int resolveCalls = 0;
  int saveCalls = 0;

  final ScreenShareDecisionEngine engine = ScreenShareDecisionEngine();
  // Lets a test hold the resolve() promise open to exercise coalescing.
  Completer<ScreenShareDecision>? gate;

  /// Whether this site is the one on screen (SHARE-011).
  bool active;

  _Host({this.mode = ScreenShareMode.ask, this.source, this.active = true});

  Future<ScreenShareDecision> decide(String origin) => engine.decide(
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

const _src = VirtualScreenSource(
  kind: 'image',
  dataUrl: 'data:image/png;base64,AAAA',
  fileName: 'slide.png',
);

void main() {
  group('ScreenShareDecisionEngine', () {
    test('block short-circuits without UI or save', () async {
      final host = _Host(mode: ScreenShareMode.block);
      final d = await host.decide('https://meet.example');
      expect(d.mode, ScreenShareMode.block);
      expect(host.resolveCalls, 0);
      expect(host.saveCalls, 0);
    });

    test('virtual with a source short-circuits and returns the source',
        () async {
      final host = _Host(mode: ScreenShareMode.virtual, source: _src);
      final d = await host.decide('https://meet.example');
      expect(d.mode, ScreenShareMode.virtual);
      expect(d.source, same(_src));
      expect(host.resolveCalls, 0);
    });

    test('virtual with no source yet re-offers the picker', () async {
      final host = _Host(mode: ScreenShareMode.virtual);
      host.onResolve = (_, current) {
        expect(current, ScreenShareMode.virtual);
        return const ScreenShareDecision(ScreenShareMode.virtual, _src);
      };
      final d = await host.decide('https://meet.example');
      expect(host.resolveCalls, 1);
      expect(d.source, same(_src));
      expect(host.source, same(_src));
      expect(host.saveCalls, 1);
    });

    test('ask prompts once, persists, and later requests are silent', () async {
      final host = _Host();
      host.onResolve = (_, _) => const ScreenShareDecision.block();
      expect((await host.decide('https://meet.example')).mode,
          ScreenShareMode.block);
      expect(host.mode, ScreenShareMode.block);
      expect(host.saveCalls, 1);

      expect((await host.decide('https://meet.example')).mode,
          ScreenShareMode.block);
      expect(host.resolveCalls, 1, reason: 'stored decision short-circuits');
    });

    test('a burst of requests shares one popup', () async {
      final host = _Host();
      host.gate = Completer<ScreenShareDecision>();
      final pending = [
        host.decide('https://meet.example'),
        host.decide('https://meet.example'),
        host.decide('https://meet.example'),
      ];
      host.gate!
          .complete(const ScreenShareDecision(ScreenShareMode.virtual, _src));
      final results = await Future.wait(pending);
      expect(host.resolveCalls, 1);
      for (final d in results) {
        expect(d.mode, ScreenShareMode.virtual);
        expect(d.source, same(_src));
      }
    });

    test('a cancelled pick keeps the prior source and re-prompts next time',
        () async {
      final host = _Host(mode: ScreenShareMode.virtual);
      host.onResolve = (_, _) =>
          const ScreenShareDecision(ScreenShareMode.virtual);
      final d = await host.decide('https://meet.example');
      expect(d.mode, ScreenShareMode.virtual);
      expect(d.source, isNull);
      expect(host.source, isNull, reason: 'a null source never overwrites');

      await host.decide('https://meet.example');
      expect(host.resolveCalls, 2, reason: 'still unresolved, ask again');
    });

    test('a backgrounded site is denied in every mode (SHARE-011)', () async {
      for (final mode in ScreenShareMode.values) {
        final host = _Host(
          mode: mode,
          source: mode == ScreenShareMode.virtual ? _src : null,
          active: false,
        );
        host.onResolve = (_, _) => fail('a background site must not prompt');
        final d = await host.decide('https://meet.example');
        expect(d.mode, ScreenShareMode.block, reason: 'stored mode $mode');
        expect(d.source, isNull);
        expect(d.toBridgeJson(), {'mode': 'block'});
        expect(host.resolveCalls, 0);
        expect(host.saveCalls, 0);
        expect(host.mode, mode, reason: 'the stored decision is left intact');
        expect(host.source, mode == ScreenShareMode.virtual ? _src : isNull,
            reason: 'the picked source is left intact');
      }
    });

    test('the site decides normally once it is active again', () async {
      final host = _Host(active: false);
      expect((await host.decide('https://meet.example')).mode,
          ScreenShareMode.block);
      expect(host.resolveCalls, 0);
      host.active = true;
      host.onResolve = (_, _) =>
          const ScreenShareDecision(ScreenShareMode.virtual, _src);
      expect((await host.decide('https://meet.example')).mode,
          ScreenShareMode.virtual);
      expect(host.resolveCalls, 1);
    });

    test('switching away mid-prompt does not retract the answer', () async {
      final host = _Host();
      host.gate = Completer<ScreenShareDecision>();
      final pending = host.decide('https://meet.example');
      // User answers the popup after the site lost focus.
      host.active = false;
      host.gate!
          .complete(const ScreenShareDecision(ScreenShareMode.virtual, _src));
      expect((await pending).mode, ScreenShareMode.virtual);
      expect(host.mode, ScreenShareMode.virtual);
      // The next request from the now-backgrounded site is still denied.
      expect((await host.decide('https://meet.example')).mode,
          ScreenShareMode.block);
    });

    test('a dismissed popup stays ask so the next request prompts again',
        () async {
      final host = _Host();
      host.onResolve = (_, _) => const ScreenShareDecision(ScreenShareMode.ask);
      final d = await host.decide('https://meet.example');
      expect(d.mode, ScreenShareMode.ask,
          reason: 'the bridge maps ask to block; the engine keeps it honest');
      expect(host.mode, ScreenShareMode.ask);
      await host.decide('https://meet.example');
      expect(host.resolveCalls, 2);
    });
  });
}
