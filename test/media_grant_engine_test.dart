import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/services/site_origins.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/settings/origin_choices.dart';
import 'package:webspace/settings/site_permission_state.dart';

import 'helpers/capture_fakes.dart';

const _top = 'https://site.example';
const _frame = 'https://ads.example';

/// Drives the real [GrantStore] against in-memory storage, the way the nested
/// screen does; [PersistedGrantStore] differs only in where it records, which
/// test/capture_request_wiring_test.dart covers through the model.
final class _Host {
  _Host(
    CaptureKind kind, {
    required CaptureMode mode,
    bool withSource = false,
    Answer Function(CaptureKind kind,
        {required String origin, required CaptureMode current})? answer,
    OriginMemory? origins,
  }) : prompter = FakePrompter(answer) {
    store = InMemoryGrantStore(
      (capture: grantsWith(kind, mode: mode, withSource: withSource),
          protectedContent: null),
      prompter: prompter,
      isSiteActive: () => active,
      origins: origins ?? TransientOrigins(),
    );
  }

  final FakePrompter prompter;
  late final GrantStore store;
  bool active = true;

  Future<CaptureGrant> ask(
    CaptureKind kind, {
    String origin = _top,
    Standing standing = Standing.own,
  }) => store.capture(kind, origin: origin, standing: standing);

  CaptureGrant stored(CaptureKind kind) =>
      kind.grantOf(store.media.capture);
}

Answer Function(CaptureKind kind,
    {required String origin, required CaptureMode current}) _always(
        Answer a) =>
    (_, {required origin, required current}) => a;

void main() {
  for (final kind in CaptureKind.values) {
    group('GrantStore.capture for $kind', () {
      test('block settles without a popup', () async {
        final host = _Host(kind, mode: kind.block);
        expect((await host.ask(kind)).mode, kind.block);
        expect(host.prompter.asked, isEmpty);
      });

      test('virtual with a file settles and serves it', () async {
        final host = _Host(kind, mode: kind.virtual, withSource: true);
        final grant = await host.ask(kind);
        expect(grant.mode, kind.virtual);
        expect(grant.source, pickedFor(kind));
        expect(host.prompter.asked, isEmpty);
      });

      test('virtual with no file yet re-offers the picker each time', () async {
        final host =
            _Host(kind, mode: kind.virtual, answer: _always(Answer.cancelPick));
        await host.ask(kind);
        await host.ask(kind);
        expect(host.prompter.asked.map((a) => a.$3), [kind.virtual, kind.virtual]);
        expect(host.stored(kind).source, isNull,
            reason: 'a cancelled pick never writes a source');
      });

      test('ask prompts once, records the answer, then settles', () async {
        final host =
            _Host(kind, mode: kind.ask, answer: _always(Answer.useFile));
        final grant = await host.ask(kind);
        expect(grant.mode, kind.virtual);
        expect(grant.source, pickedFor(kind));
        expect(host.stored(kind), (mode: kind.virtual, source: pickedFor(kind)));
        host.prompter.answer = null;
        expect((await host.ask(kind)).source, pickedFor(kind));
      });

      test('a dismissed popup stays ask, denied this once', () async {
        final host =
            _Host(kind, mode: kind.ask, answer: _always(Answer.dismiss));
        final grant = await host.ask(kind);
        expect(grant.mode, kind.ask);
        expect(grant.toBridgeJson(), {'mode': 'block'});
        await host.ask(kind);
        expect(host.prompter.asked, hasLength(2));
      });

      test('a burst shares one popup', () async {
        final host = _Host(kind, mode: kind.ask, answer: _always(Answer.block));
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
          final host = _Host(kind, mode: mode, withSource: true);
          host.active = false;
          final grant = await host.ask(kind);
          expect(grant.toBridgeJson(), {'mode': 'block'}, reason: '$mode');
          expect(grant.source, isNull);
          expect(host.stored(kind).mode, mode, reason: 'stored decision kept');
        }
      });

      test('switching away mid-prompt does not retract the answer', () async {
        final host =
            _Host(kind, mode: kind.ask, answer: _always(Answer.useFile));
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
          final host = _Host(kind, mode: mode, withSource: withSource);
          final grant = await host.ask(kind, origin: _frame, standing: Standing.embedded);
          expect(grant.mode, mode);
          expect(host.prompter.asked, isEmpty);
        }
      });
    });
  }

  for (final kind in <CaptureKind>[CaptureKind.camera, CaptureKind.microphone]) {
    group('GrantStore.capture frame scoping for $kind (CAM-014 / MIC-016)', () {
      test('real settles for the top document', () async {
        final host = _Host(kind, mode: kind.real);
        expect((await host.ask(kind)).toBridgeJson(), {'mode': 'real'});
        expect(host.prompter.asked, isEmpty);
      });

      test('a subframe does not inherit a settled real grant', () async {
        final host = _Host(kind, mode: kind.real);
        host.prompter.originAnswer = (_, {required origin}) => false;
        final grant = await host.ask(kind, origin: _frame, standing: Standing.embedded);
        expect(grant.mode, kind.block);
        expect(host.prompter.originsAsked.single,
            (SitePermission.ofCapture(kind), _frame),
            reason: 'the popup names the frame');
        expect(host.stored(kind).mode, kind.real);
      });

      test('a subframe answer is never written back to the site', () async {
        final host = _Host(kind, mode: kind.ask);
        host.prompter.originAnswer = (_, {required origin}) => true;
        final grant = await host.ask(kind, origin: _frame, standing: Standing.embedded);
        expect(grant.mode, kind.real);
        expect(host.stored(kind).mode, kind.ask);
      });

      test('the platform follow-up reads the frame answer', () async {
        final host = _Host(kind, mode: kind.ask);
        host.prompter.originAnswer = (_, {required origin}) => true;
        await host.ask(kind, origin: _frame, standing: Standing.embedded);
        final again = await host.ask(kind, origin: _frame, standing: Standing.embedded);
        expect(again.mode, kind.real);
        expect(host.prompter.originsAsked, hasLength(1));
      });

      test('a frame answer does not leak to another frame', () async {
        final host = _Host(kind, mode: kind.ask);
        host.prompter.originAnswer = (_, {required origin}) => origin == _frame;
        await host.ask(kind, origin: _frame, standing: Standing.embedded);
        final other = await host.ask(kind,
            origin: 'https://other.example', standing: Standing.embedded);
        expect(other.mode, kind.block);
        expect(host.prompter.originsAsked, hasLength(2));
      });

      test("a subframe does not ride the top document's popup", () async {
        final host = _Host(kind, mode: kind.ask, answer: _always(Answer.allow));
        host.prompter.originAnswer = (_, {required origin}) => true;
        host.prompter.gate = Completer<void>();
        final top = host.ask(kind);
        final frame = host.ask(kind, origin: _frame, standing: Standing.embedded);
        await pumpEventQueue();
        host.prompter.gate!.complete();
        await Future.wait([top, frame]);
        expect(host.prompter.asked, hasLength(1));
        expect(host.prompter.originsAsked, hasLength(1));
      });
    });
  }

  test('two kinds asking at once are two questions', () async {
    // One store serves every kind, so coalescing is keyed by kind as well as
    // origin: a camera answer must never settle a microphone request.
    final host = _Host(CaptureKind.camera,
        mode: CameraAccessMode.ask,
        answer: (kind, {required origin, required current}) =>
            kind == CaptureKind.camera ? Answer.allow : Answer.block);
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
        prompter: prompter, isSiteActive: () => true, origins: TransientOrigins());
    for (final kind in <CaptureKind>[CaptureKind.camera, CaptureKind.microphone]) {
      expect(store.mode(kind, origin: _top, standing: Standing.own).state,
          SitePermissionState.ask);
      await store.capture(kind, origin: _top, standing: Standing.own);
    }
    expect(prompter.asked, hasLength(2));
  });

  group('GrantStore.protectedContent', () {
    InMemoryGrantStore store(FakePrompter prompter, {required bool? remembered}) =>
        InMemoryGrantStore(
          (capture: CaptureGrants.none, protectedContent: remembered),
          prompter: prompter,
          isSiteActive: () => true,
          origins: TransientOrigins(),
        );

    test('a remembered answer settles without a popup', () async {
      final prompter = FakePrompter();
      expect(await store(prompter, remembered: false).protectedContent(_top, standing: Standing.own),
          isFalse);
      expect(await store(prompter, remembered: true).protectedContent(_top, standing: Standing.own),
          isTrue);
      expect(prompter.drmAsked, 0);
    });

    test('a burst shares one popup and the answer is remembered', () async {
      final prompter = FakePrompter()
        ..drmAnswer = true
        ..gate = Completer<void>();
      final s = store(prompter, remembered: null);
      final burst = [s.protectedContent(_top, standing: Standing.own), s.protectedContent(_top, standing: Standing.own)];
      await pumpEventQueue();
      prompter.gate!.complete();
      expect(await Future.wait(burst), [true, true]);
      expect(prompter.drmAsked, 1);
      expect(s.media.protectedContent, isTrue);
    });
  });

  // A page the site does not own: one a link reached in a nested screen or a
  // tab, or the next page a surface navigated to.
  const foreign = 'https://evil.example';
  for (final kind in CaptureKind.values) {
    final permission = SitePermission.ofCapture(kind);
    group('PERM-001 / PERM-002: a grant answers for the origin that gave it '
        '($kind)', () {
      test("a foreign document does not ride the site's real grant", () async {
        final host = _Host(kind, mode: kind.real);
        host.prompter.originAnswer = (_, {required origin}) => false;
        final grant =
            await host.ask(kind, origin: foreign, standing: Standing.foreign);
        expect(grant.mode, kind.block);
        if (kind.realOffered) {
          expect(host.prompter.originsAsked.single, (permission, foreign),
              reason: 'the popup names the page that asks');
        }
        expect(host.prompter.asked, isEmpty,
            reason: "the site's own popup, with its file, is not shown");
        expect(host.stored(kind).mode, kind.real,
            reason: "the site's own grant is left as it was");
      });

      test("a foreign document is not served the site's file", () async {
        final host = _Host(kind, mode: kind.virtual, withSource: true);
        host.prompter.originAnswer = (_, {required origin}) => true;
        final grant =
            await host.ask(kind, origin: foreign, standing: Standing.foreign);
        expect(grant.source, isNull);
        expect(grant.mode, kind.realOffered ? kind.real : kind.block,
            reason: 'its own answer, Allow or Block, never the file');
      });

      test('a foreign answer stays with its origin, and is remembered for it',
          () async {
        final origins = TransientOrigins();
        final host = _Host(kind, mode: kind.ask, origins: origins,
            answer: _always(Answer.block));
        host.prompter.originAnswer = (_, {required origin}) => true;
        expect(
            (await host.ask(kind, origin: foreign, standing: Standing.foreign))
                .mode,
            kind.realOffered ? kind.real : kind.block);
        expect(host.stored(kind).mode, kind.ask,
            reason: 'never written to the site');
        if (!kind.realOffered) return;
        expect(origins.choices.of(permission, origin: foreign), isTrue);
        final later = _Host(kind, mode: kind.ask, origins: origins);
        expect(
            (await later.ask(kind, origin: foreign, standing: Standing.foreign))
                .mode,
            kind.real,
            reason: 'another surface of the site reads the same answer');
        expect(later.prompter.originsAsked, isEmpty);
        host.prompter.originAnswer = (_, {required origin}) => false;
        expect(
            (await host.ask(kind,
                    origin: 'https://next.example', standing: Standing.foreign))
                .mode,
            kind.block,
            reason: 'the next origin is asked for itself');
        expect((await host.ask(kind)).mode, kind.block,
            reason: "and so is the site's own document, by its own popup");
        expect(host.prompter.originsAsked, hasLength(2));
        expect(host.prompter.asked, hasLength(1));
      });

      test('a dismissed origin popup is denied once and asked again', () async {
        if (!kind.realOffered) return;
        final host = _Host(kind, mode: kind.ask);
        host.prompter.originAnswer = (_, {required origin}) => null;
        for (var i = 0; i < 2; i++) {
          expect(
              (await host.ask(kind, origin: foreign, standing: Standing.foreign))
                  .mode,
              kind.block);
        }
        expect(host.prompter.originsAsked, hasLength(2));
      });

      test("the site's block holds for a foreign document", () async {
        final origins = TransientOrigins()
          ..choices = OriginChoices.none
              .remember(permission, origin: foreign, allowed: true);
        final host = _Host(kind, mode: kind.block, origins: origins);
        expect(
            (await host.ask(kind, origin: foreign, standing: Standing.foreign))
                .mode,
            kind.block);
        expect(host.prompter.originsAsked, isEmpty);
      });

      test('a backgrounded site asks no other origin', () async {
        final host = _Host(kind, mode: kind.ask)..active = false;
        expect(
            (await host.ask(kind, origin: foreign, standing: Standing.foreign))
                .mode,
            kind.block);
        expect(host.prompter.originsAsked, isEmpty);
      });

      test('a foreign document reads its own answer, else ask', () {
        final origins = TransientOrigins();
        final host = _Host(kind, mode: kind.real, origins: origins);
        expect(
            host.store.mode(kind, origin: foreign, standing: Standing.foreign),
            kind.ask);
        origins.choices = origins.choices
            .remember(permission, origin: foreign, allowed: false);
        expect(
            host.store.mode(kind, origin: foreign, standing: Standing.foreign),
            kind.block);
        expect(host.store.mode(kind, origin: _top, standing: Standing.own),
            kind.real);
        expect(
            _Host(kind, mode: kind.block)
                .store
                .mode(kind, origin: foreign, standing: Standing.foreign),
            kind.block);
      });

      test("the site's own answer to Block forgets its other origins", () async {
        final origins = TransientOrigins()
          ..choices = OriginChoices.none
              .remember(permission, origin: foreign, allowed: true)
              .remember(SitePermission.location, origin: foreign, allowed: true);
        final host = _Host(kind, mode: kind.ask, origins: origins,
            answer: _always(Answer.block));
        await host.ask(kind);
        expect(origins.choices.listed(permission), isEmpty);
        expect(origins.choices.of(SitePermission.location, origin: foreign),
            isTrue, reason: 'only the capability that moved');
      });
    });
  }

  group('PERM-001 / PERM-002: protected content, location and notifications '
      'answer for the origin that asked', () {
    InMemoryGrantStore store(FakePrompter prompter, {bool? protectedContent}) =>
        InMemoryGrantStore(
          (capture: CaptureGrants.none, protectedContent: protectedContent),
          prompter: prompter,
          isSiteActive: () => true,
          origins: TransientOrigins(),
        );

    test('protected content: a foreign origin is asked for itself, once',
        () async {
      final prompter = FakePrompter()
        ..drmAnswer = false
        ..originAnswer = (_, {required origin}) => true;
      final s = store(prompter);
      expect(await s.protectedContent(foreign, standing: Standing.foreign),
          isTrue);
      expect(await s.protectedContent(foreign, standing: Standing.embedded),
          isTrue);
      expect(prompter.originsAsked,
          [(SitePermission.protectedContent, foreign)]);
      expect(s.media.protectedContent, isNull,
          reason: 'never written to the site');
      expect(await s.protectedContent(_top, standing: Standing.own), isFalse,
          reason: "the site's own document asks by the site's popup");
      expect(prompter.drmAsked, 1);
    });

    test("protected content: the site's block holds for every origin",
        () async {
      final prompter = FakePrompter();
      expect(
          await store(prompter, protectedContent: false)
              .protectedContent(foreign, standing: Standing.foreign),
          isFalse);
      expect(prompter.originsAsked, isEmpty);
    });

    test('location (LOC-012): served to the site, asked of another origin',
        () async {
      final prompter = FakePrompter()
        ..originAnswer = (_, {required origin}) => origin == foreign;
      final s = store(prompter);
      expect(await s.location(_top, standing: Standing.own, live: true), isTrue);
      expect(await s.location(foreign, standing: Standing.foreign, live: true),
          isTrue);
      expect(await s.location(_frame, standing: Standing.embedded, live: true),
          isFalse);
      expect(await s.location(foreign, standing: Standing.foreign, live: true),
          isTrue);
      expect(prompter.originsAsked, [
        (SitePermission.location, foreign),
        (SitePermission.location, _frame),
      ]);
      expect(await s.location(foreign, standing: Standing.foreign, live: false),
          isFalse, reason: 'a site not set to live serves no origin');
    });

    test('notifications (NOTIF-020): the site may, another origin is asked',
        () async {
      final prompter = FakePrompter()
        ..originAnswer = (_, {required origin}) => false;
      final s = store(prompter);
      expect(await s.notifications(_top, standing: Standing.own, enabled: true),
          isTrue);
      expect(
          await s.notifications(foreign,
              standing: Standing.foreign, enabled: true),
          isFalse);
      expect(
          await s.notifications(foreign,
              standing: Standing.foreign, enabled: true),
          isFalse);
      expect(prompter.originsAsked, hasLength(1));
      expect(
          await s.notifications(_top, standing: Standing.own, enabled: false),
          isFalse);
    });
  });

  test('PERM-002: an answer outlives its surface, saved with the site',
      () async {
    final site = siteWith(CaptureKind.camera, mode: CameraAccessMode.ask);
    var saves = 0;
    final prompter = FakePrompter()
      ..originAnswer = (_, {required origin}) => true;
    final first = PersistedGrantStore(site,
        prompter: prompter, isSiteActive: () => true, save: () async => saves++);
    await first.capture(CaptureKind.camera,
        origin: foreign, standing: Standing.foreign);
    expect(site.originChoices.of(SitePermission.camera, origin: foreign),
        isTrue);
    expect(saves, 1);
    final nested = InMemoryGrantStore(site.effectiveMedia,
        prompter: FakePrompter(),
        isSiteActive: () => true,
        origins: SavedOrigins(site, save: () async => saves++));
    expect(
        (await nested.capture(CaptureKind.camera,
                origin: foreign, standing: Standing.foreign))
            .mode,
        CameraAccessMode.real,
        reason: "a nested screen reads the site's answers");
  });
}
