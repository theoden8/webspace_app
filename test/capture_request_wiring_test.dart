import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_grant_engine.dart';
import 'package:webspace/settings/capture.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/capture_fakes.dart';

/// Drives the store `getWebView` hands a site's own webview: a
/// [PersistedGrantStore] over the real `WebViewModel`, rather than the engine
/// over in-memory storage.
///
/// The engine tests prove the gate; they cannot prove the model reads and
/// records through it correctly. Read the stored captures instead of the
/// effective ones and an archived site prompts (CAM-006 / MIC-006 /
/// SHARE-006); record onto the effective view and its stored intent is lost.
GrantStore _store(
  WebViewModel model, {
  MediaPrompter? prompter,
  bool Function()? isActive,
  void Function()? onSave,
}) => PersistedGrantStore(
  model,
  prompter: prompter ?? FakePrompter(),
  isSiteActive: isActive ?? () => true,
  save: () async => onSave?.call(),
);

void main() {
  const origin = 'https://site.example';

  for (final kind in CaptureKind.values) {
    group('PersistedGrantStore for $kind', () {
      test('a backgrounded site is denied without prompting', () async {
        for (final mode in kind.modes) {
          final model = siteWith(kind, mode: mode, withSource: true);
          var saves = 0;
          final grant = await _store(
            model,
            isActive: () => false,
            onSave: () => saves++,
          ).capture(kind, origin: origin, isTopFrame: true);
          expect(grant.toBridgeJson(), {'mode': 'block'}, reason: '$mode');
          expect(kind.grantOf(model.captures).mode, mode,
              reason: 'stored decision left intact');
          expect(saves, 0);
        }
      });

      test('the active site resolves, persists and saves', () async {
        final model = siteWith(kind, mode: kind.ask);
        var saves = 0;
        final grant = await _store(
          model,
          prompter: FakePrompter(
              (_, {required origin, required current}) => Answer.useFile),
          onSave: () => saves++,
        ).capture(kind, origin: origin, isTopFrame: true);
        expect(grant.mode, kind.virtual);
        expect(kind.grantOf(model.captures),
            (mode: kind.virtual, source: pickedFor(kind)));
        expect(saves, 1);
      });

      test('the archive-tier fold survives the wiring (CAM-006 / MIC-006 / '
          'SHARE-006)', () async {
        final model = siteWith(kind,
            mode: kind.virtual, withSource: true, archived: true);
        final store = _store(model);
        expect(
            (await store.capture(kind, origin: origin, isTopFrame: true)).mode,
            kind.block);
        expect(store.mode(kind), kind.block,
            reason: 'enumerateDevices reads the folded mode too');
        expect(kind.grantOf(model.captures).mode, kind.virtual,
            reason: 'preserved for when the site leaves the archive');
      });

      test('the activity predicate is read per request', () async {
        var active = true;
        final store = _store(
            siteWith(kind, mode: kind.virtual, withSource: true),
            isActive: () => active);
        expect(
            (await store.capture(kind, origin: origin, isTopFrame: true)).mode,
            kind.virtual);
        active = false;
        expect(
            (await store.capture(kind, origin: origin, isTopFrame: true)).mode,
            kind.block);
      });
    });
  }

  test('a stored real microphone settles without prompting (MIC-001)',
      () async {
    var saves = 0;
    final grant = await _store(
      siteWith(CaptureKind.microphone, mode: MicrophoneAccessMode.real),
      onSave: () => saves++,
    ).capture(CaptureKind.microphone, origin: origin, isTopFrame: true);
    expect(grant.toBridgeJson(), {'mode': 'real'});
    expect(saves, 0, reason: 'nothing changed, so nothing to persist');
  });

  test('no answer can produce a real-display grant (SHARE-001)', () async {
    // The host UI is the only thing that could widen this, and it has no
    // value to widen it to: every answer maps to a payload the shim reads as
    // "serve a file" or "deny".
    for (final answer in Answer.values) {
      final grant = await _store(
        siteWith(CaptureKind.screenShare, mode: ScreenShareMode.ask),
        prompter:
            FakePrompter((_, {required origin, required current}) => answer),
      ).capture(CaptureKind.screenShare, origin: origin, isTopFrame: true);
      expect(grant.toBridgeJson()['mode'], isIn(['virtual', 'block']),
          reason: answer.name);
    }
  });

  test('a protected-content answer is recorded on the model and saved',
      () async {
    final model =
        WebViewModel(initUrl: origin, trackingProtectionEnabled: false);
    var saves = 0;
    final store = _store(model,
        prompter: FakePrompter()..drmAnswer = true, onSave: () => saves++);
    expect(await store.protectedContent(origin), isTrue);
    expect(model.protectedContentAllowed, isTrue);
    expect(saves, 1);
  });

  test('Tracking Protection denies protected content without a popup', () async {
    final model = WebViewModel(initUrl: origin, trackingProtectionEnabled: true)
      ..protectedContentAllowed = true;
    expect(await _store(model).protectedContent(origin), isFalse);
  });
}
