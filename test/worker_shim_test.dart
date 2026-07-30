import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/services/anti_fingerprinting_shim.dart';
import 'package:webspace/services/language_shim.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/services/user_agent_identity_shim.dart';
import 'package:webspace/services/worker_shim.dart';
import 'package:webspace/settings/location.dart';

/// Strip JS comments so a structural check inspects code, not prose (the shim
/// sources legitimately discuss `window.inner*` in comments).
String _stripJsComments(String js) => js
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  // Every shim injected into a worker global scope must be scope-agnostic.
  // `window` is a ReferenceError there, and because the payload is one script
  // of concatenated IIFEs, a single uncaught throw silences every shim after
  // it — so this is a hard gate, not a style preference. Add a shim to the
  // worker payload in webview.dart and it must pass here too.
  group('worker-payload shims are scope-agnostic', () {
    final workerScopeShims = <String, String>{
      'language': buildLanguageShim('en'),
      'ua_identity':
          buildUserAgentIdentityShim(buildFirefoxAndroidUserAgent('152.0'))!,
      'anti_fingerprinting': buildAntiFingerprintingShim('seed'),
      'location_timezone': LocationSpoofService.buildScript(
        locationMode: LocationMode.off,
        spoofLatitude: null,
        spoofLongitude: null,
        spoofAccuracy: 50.0,
        spoofTimezone: 'UTC',
        webRtcPolicy: WebRtcPolicy.disabled,
      )!,
    };

    for (final entry in workerScopeShims.entries) {
      test('${entry.key} never dereferences `window`', () {
        final code = _stripJsComments(entry.value);
        expect(code, isNot(contains('window.')),
            reason: '${entry.key} must use globalThis (worker scope has no '
                'window); a throw here silences later shims in the payload');
        expect(code, isNot(contains('window[')));
      });

      test('${entry.key} resolves the navigator prototype dynamically', () {
        // Naming `Navigator` breaks in a worker, where the class is
        // WorkerNavigator.
        final code = _stripJsComments(entry.value);
        if (code.contains('navigator')) {
          expect(code, isNot(contains('Navigator.prototype')),
              reason: '${entry.key} must use Object.getPrototypeOf(navigator)');
        }
      });
    }
  });

  group('buildWorkerShimScript', () {
    test('returns null when there is nothing to propagate', () {
      // No active spoofing => stock constructors, so a site that gains nothing
      // from the blob indirection cannot be broken by it.
      expect(buildWorkerShimScript(const []), isNull);
      expect(buildWorkerShimScript(const ['', '   ', '\n']), isNull);
    });

    test('embeds the shim sources as the worker payload', () {
      final lang = buildLanguageShim('en');
      final script = buildWorkerShimScript([lang])!;
      // The payload is embedded as a JS string literal, so the shim body
      // appears JSON-encoded rather than verbatim.
      expect(script, contains(jsonEncode(lang).substring(1, 60)));
      expect(script, contains('__wsInstallWorkerWrap'));
    });

    test('patches both Worker and SharedWorker', () {
      final script = buildWorkerShimScript([buildLanguageShim('en')])!;
      expect(script, contains("patch('Worker');"));
      expect(script, contains("patch('SharedWorker');"));
    });

    test('preserves source order of the shims in the payload', () {
      final first = buildLanguageShim('en');
      final second = buildLanguageShim('fr-FR');
      final script = buildWorkerShimScript([first, second])!;
      // Compare positions of the two distinct language tags inside the encoded
      // payload; injection order must survive into worker scope.
      expect(script.indexOf(r'\"en\"'), lessThan(script.indexOf(r'\"fr-FR\"')));
    });

    test('payload carries the nested-worker re-install', () {
      final script = buildWorkerShimScript([buildLanguageShim('en')])!;
      // __wsShimUrl is how a worker learns its own blob URL so it can wrap the
      // workers it spawns.
      expect(script, contains(r'__wsShimUrl'));
    });

    test('caches wrapped URLs so SharedWorker identity survives', () {
      final script = buildWorkerShimScript([buildLanguageShim('en')])!;
      expect(script, contains('_wrapped'));
      expect(script, contains('_wrapped.get(key)'));
    });

    test('builder appends no evaluator tail (the call site owns that)', () {
      final script = buildWorkerShimScript([buildLanguageShim('en')])!;
      expect(script.trimRight().endsWith('})();'), isTrue);
    });
  });
}
