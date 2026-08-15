import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/microphone_decision_engine.dart';
import 'package:webspace/settings/microphone.dart';

/// Drives the real [MicrophoneDecisionEngine] against in-memory storage, the
/// way both the model and the nested screen do — never re-implementing the
/// flow.
class _Host {
  MicrophoneAccessMode mode;
  VirtualMicrophoneSource? source;

  /// What the host UI (`resolve`) will return next.
  MicrophoneDecision Function(String origin, MicrophoneAccessMode current)?
      onResolve;

  int resolveCalls = 0;
  int saveCalls = 0;

  final MicrophoneDecisionEngine engine = MicrophoneDecisionEngine();
  // Lets a test hold the resolve() promise open to exercise coalescing.
  Completer<MicrophoneDecision>? gate;

  _Host({this.mode = MicrophoneAccessMode.ask, this.source});

  Future<MicrophoneDecision> decide(String origin) => engine.decide(
        origin: origin,
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

const _src = VirtualMicrophoneSource(
  dataUrl: 'data:audio/mpeg;base64,AAAA',
  fileName: 'tone.mp3',
);

void main() {
  group('MicrophoneDecisionEngine', () {
    test('block short-circuits without UI or save', () async {
      final host = _Host(mode: MicrophoneAccessMode.block);
      final d = await host.decide('https://meet.example');
      expect(d.mode, MicrophoneAccessMode.block);
      expect(host.resolveCalls, 0);
      expect(host.saveCalls, 0);
    });

    test('virtual with a source short-circuits and returns the source',
        () async {
      final host = _Host(mode: MicrophoneAccessMode.virtual, source: _src);
      final d = await host.decide('https://meet.example');
      expect(d.mode, MicrophoneAccessMode.virtual);
      expect(d.source, same(_src));
      expect(host.resolveCalls, 0);
    });

    test('virtual with no source yet re-offers the picker', () async {
      final host = _Host(mode: MicrophoneAccessMode.virtual);
      host.onResolve = (_, current) {
        expect(current, MicrophoneAccessMode.virtual);
        return const MicrophoneDecision(MicrophoneAccessMode.virtual, _src);
      };
      final d = await host.decide('https://meet.example');
      expect(host.resolveCalls, 1);
      expect(d.source, same(_src));
      expect(host.source, same(_src));
      expect(host.saveCalls, 1);
    });

    test('ask prompts once, persists, and later requests are silent', () async {
      final host = _Host();
      host.onResolve = (_, _) => const MicrophoneDecision.block();
      expect((await host.decide('https://meet.example')).mode,
          MicrophoneAccessMode.block);
      expect(host.mode, MicrophoneAccessMode.block);
      expect(host.saveCalls, 1);

      expect((await host.decide('https://meet.example')).mode,
          MicrophoneAccessMode.block);
      expect(host.resolveCalls, 1, reason: 'stored decision short-circuits');
    });

    test('a burst of requests shares one popup', () async {
      final host = _Host();
      host.gate = Completer<MicrophoneDecision>();
      final pending = [
        host.decide('https://meet.example'),
        host.decide('https://meet.example'),
        host.decide('https://meet.example'),
      ];
      host.gate!.complete(
          const MicrophoneDecision(MicrophoneAccessMode.virtual, _src));
      final results = await Future.wait(pending);
      expect(host.resolveCalls, 1);
      for (final d in results) {
        expect(d.mode, MicrophoneAccessMode.virtual);
        expect(d.source, same(_src));
      }
    });

    test('a cancelled pick keeps the prior source and re-prompts next time',
        () async {
      final host = _Host(mode: MicrophoneAccessMode.virtual, source: _src);
      // Force the unresolved path by dropping the source first.
      host.source = null;
      host.onResolve = (_, _) =>
          const MicrophoneDecision(MicrophoneAccessMode.virtual);
      final d = await host.decide('https://meet.example');
      expect(d.mode, MicrophoneAccessMode.virtual);
      expect(d.source, isNull);
      expect(host.source, isNull, reason: 'a null source never overwrites');

      await host.decide('https://meet.example');
      expect(host.resolveCalls, 2, reason: 'still unresolved, ask again');
    });

    test('a dismissed popup stays ask so the next request prompts again',
        () async {
      final host = _Host();
      host.onResolve = (_, _) =>
          const MicrophoneDecision(MicrophoneAccessMode.ask);
      final d = await host.decide('https://meet.example');
      expect(d.mode, MicrophoneAccessMode.ask,
          reason: 'the bridge maps ask to block; the engine keeps it honest');
      expect(host.mode, MicrophoneAccessMode.ask);
      await host.decide('https://meet.example');
      expect(host.resolveCalls, 2);
    });
  });
}
