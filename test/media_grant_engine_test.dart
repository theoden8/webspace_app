import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/site_permission_state.dart';

import 'helpers/capture_fakes.dart';

const _top = 'https://site.example';
const _frame = 'https://ads.example';

/// Drives the real [GrantStore] against in-memory storage, the way the nested
/// screen does; [PersistedGrantStore] differs only in where it records, which
/// test/capture_request_wiring_test.dart covers through the model.
final class _Host {
  _Host(
    CaptureKind kind,
    CaptureMode mode, {
    bool withSource = false,
    Answer Function(CaptureKind, String, CaptureMode)? answer,
  }) : prompter = FakePrompter(answer) {
    store = InMemoryGrantStore(
      (capture: grantsWith(kind, mode, withSource: withSource),
          protectedContent: null),
      prompter: prompter,
      isSiteActive: () => active,
    );
  }

  final FakePrompter prompter;
  late final GrantStore store;
  bool active = true;

  Future<AnyCaptureGrant> ask(
    CaptureKind kind, {
    String origin = _top,
    bool isTopFrame = true,
  }) => store.capture(kind, origin, isTopFrame: isTopFrame);

  AnyCaptureGrant stored(CaptureKind kind) =>
      kind.grantOf(store.media.capture);
}

Answer Function(CaptureKind, String, CaptureMode) _always(Answer a) =>
    (_, _, _) => a;

void main() {
  for (final kind in CaptureKind.values) {
    group('GrantStore.capture for $kind', () {
      test('block settles without a popup', () async {
        final host = _Host(kind, kind.block);
        expect((await host.ask(kind)).mode, kind.block);
        expect(host.prompter.asked, isEmpty);
      });

      test('virtual with a file settles and serves it', () async {
        final host = _Host(kind, kind.virtual, withSource: true);
        final grant = await host.ask(kind);
        expect(grant.mode, kind.virtual);
        expect(grant.source, pickedFor(kind));
        expect(host.prompter.asked, isEmpty);
      });

      test('virtual with no file yet re-offers the picker each time', () async {
        final host = _Host(kind, kind.virtual, answer: _always(Answer.cancelPick));
        await host.ask(kind);
        await host.ask(kind);
        expect(host.prompter.asked.map((a) => a.$3), [kind.virtual, kind.virtual]);
        expect(host.stored(kind).source, isNull,
            reason: 'a cancelled pick never writes a source');
      });

      test('ask prompts once, records the answer, then settles', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.useFile));
        final grant = await host.ask(kind);
        expect(grant.mode, kind.virtual);
        expect(grant.source, pickedFor(kind));
        expect(host.stored(kind), (mode: kind.virtual, source: pickedFor(kind)));
        host.prompter.answer = null;
        expect((await host.ask(kind)).source, pickedFor(kind));
      });

      test('a dismissed popup stays ask, denied this once', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.dismiss));
        final grant = await host.ask(kind);
        expect(grant.mode, kind.ask);
        expect(grant.toBridgeJson(), {'mode': 'block'});
        await host.ask(kind);
        expect(host.prompter.asked, hasLength(2));
      });

      test('a burst shares one popup', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.block));
        host.prompter.gate = Completer<void>();
        final burst = [host.ask(kind), host.ask(kind), host.ask(kind)];
        await pumpEventQueue();
        host.prompter.gate!.complete();
        final grants = await Future.wait(burst);
        expect(grants.map((g) => g.mode), everyElement(kind.block));
        expect(host.prompter.asked, hasLength(1));
      });

      test('a backgrounded site is denied in every mode (CAM-011 / MIC-011 / '
          'SHARE-011)', () async {
        for (final mode in kind.modes) {
          final host = _Host(kind, mode, withSource: true);
          host.active = false;
          final grant = await host.ask(kind);
          expect(grant.toBridgeJson(), {'mode': 'block'}, reason: '$mode');
          expect(grant.source, isNull);
          expect(host.stored(kind).mode, mode, reason: 'stored decision kept');
        }
      });

      test('switching away mid-prompt does not retract the answer', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.useFile));
        host.prompter.gate = Completer<void>();
        final pending = host.ask(kind);
        await pumpEventQueue();
        host.active = false;
        host.prompter.gate!.complete();
        expect((await pending).mode, kind.virtual);
        expect(host.stored(kind).mode, kind.virtual);
        expect((await host.ask(kind)).toBridgeJson(), {'mode': 'block'},
            reason: 'the next request from the backgrounded site is denied');
      });

      test('a subframe inherits the device-free answers', () async {
        for (final (mode, withSource) in [(kind.block, false), (kind.virtual, true)]) {
          final host = _Host(kind, mode, withSource: withSource);
          final grant = await host.ask(kind, origin: _frame, isTopFrame: false);
          expect(grant.mode, mode);
          expect(host.prompter.asked, isEmpty);
        }
      });
    });
  }

  for (final kind in <CaptureKind>[CaptureKind.camera, CaptureKind.microphone]) {
    group('GrantStore.capture frame scoping for $kind (CAM-014 / MIC-016)', () {
      test('real settles for the top document', () async {
        final host = _Host(kind, kind.real!);
        expect((await host.ask(kind)).toBridgeJson(), {'mode': 'real'});
        expect(host.prompter.asked, isEmpty);
      });

      test('a subframe does not inherit a settled real grant', () async {
        final host = _Host(kind, kind.real!, answer: _always(Answer.block));
        final grant = await host.ask(kind, origin: _frame, isTopFrame: false);
        expect(grant.mode, kind.block);
        expect(host.prompter.asked.single.$2, _frame,
            reason: 'the popup names the frame');
        expect(host.stored(kind).mode, kind.real);
      });

      test('a subframe answer is never written back to the site', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.allow));
        final grant = await host.ask(kind, origin: _frame, isTopFrame: false);
        expect(grant.mode, kind.real);
        expect(host.stored(kind).mode, kind.ask);
      });

      test('the platform follow-up reuses the frame answer', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.allow));
        await host.ask(kind, origin: _frame, isTopFrame: false);
        final again = await host.ask(kind, origin: _frame, isTopFrame: false);
        expect(again.mode, kind.real);
        expect(host.prompter.asked, hasLength(1));
      });

      test('the grace window does not leak to another frame', () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.allow));
        await host.ask(kind, origin: _frame, isTopFrame: false);
        host.prompter.answer = _always(Answer.block);
        final other = await host.ask(kind,
            origin: 'https://other.example', isTopFrame: false);
        expect(other.mode, kind.block);
        expect(host.prompter.asked, hasLength(2));
      });

      test("a subframe does not ride the top document's popup", () async {
        final host = _Host(kind, kind.ask, answer: _always(Answer.allow));
        host.prompter.gate = Completer<void>();
        final top = host.ask(kind);
        final frame = host.ask(kind, origin: _frame, isTopFrame: false);
        await pumpEventQueue();
        host.prompter.gate!.complete();
        await Future.wait([top, frame]);
        expect(host.prompter.asked, hasLength(2));
      });
    });
  }

  test('two kinds asking at once are two questions', () async {
    // One store serves every kind, so coalescing is keyed by kind as well as
    // origin: a camera answer must never settle a microphone request.
    final host = _Host(CaptureKind.camera, CameraAccessMode.ask,
        answer: (kind, _, _) => kind == CaptureKind.camera
            ? Answer.allow
            : Answer.block);
    host.prompter.gate = Completer<void>();
    final camera = host.ask(CaptureKind.camera);
    final microphone = host.ask(CaptureKind.microphone);
    await pumpEventQueue();
    host.prompter.gate!.complete();
    expect((await camera).mode, CameraAccessMode.real);
    expect((await microphone).mode, MicrophoneAccessMode.block);
    expect(host.prompter.asked, hasLength(2));
  });

  test('a nested store starts from the nested posture: real asks again '
      '(CAM-005 / MIC-005)', () async {
    final nested = (
      capture: CaptureGrants.none.copyWith(
        camera: (mode: CameraAccessMode.real, source: null),
        microphone: (mode: MicrophoneAccessMode.real, source: null),
      ).withoutRealGrants(),
      protectedContent: null,
    );
    final prompter = FakePrompter(_always(Answer.block));
    final store = InMemoryGrantStore(nested,
        prompter: prompter, isSiteActive: () => true);
    for (final kind in <CaptureKind>[CaptureKind.camera, CaptureKind.microphone]) {
      expect(store.mode(kind).state, SitePermissionState.ask);
      await store.capture(kind, _top, isTopFrame: true);
    }
    expect(prompter.asked, hasLength(2));
  });

  group('GrantStore.protectedContent', () {
    InMemoryGrantStore store(FakePrompter prompter, bool? remembered) =>
        InMemoryGrantStore(
          (capture: CaptureGrants.none, protectedContent: remembered),
          prompter: prompter,
          isSiteActive: () => true,
        );

    test('a remembered answer settles without a popup', () async {
      final prompter = FakePrompter();
      expect(await store(prompter, false).protectedContent(_top), isFalse);
      expect(await store(prompter, true).protectedContent(_top), isTrue);
      expect(prompter.drmAsked, 0);
    });

    test('a burst shares one popup and the answer is remembered', () async {
      final prompter = FakePrompter()
        ..drmAnswer = true
        ..gate = Completer<void>();
      final s = store(prompter, null);
      final burst = [s.protectedContent(_top), s.protectedContent(_top)];
      await pumpEventQueue();
      prompter.gate!.complete();
      expect(await Future.wait(burst), [true, true]);
      expect(prompter.drmAsked, 1);
      expect(s.media.protectedContent, isTrue);
    });
  });
}
