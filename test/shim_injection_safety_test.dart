import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/anti_fingerprinting_shim.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/language_shim.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/user_agent_identity_shim.dart';
import 'package:webspace/settings/location.dart';

/// Regression guard for the per-site JS-shim injection surface.
///
/// Per-site string settings (language, spoofTimezone, the anti-fingerprint
/// seed) reach shim JS injected at DOCUMENT_START. Those values are NOT
/// always author-controlled: a scanned QR or an imported backup carries them
/// from someone else. If any shim interpolated such a string raw instead of
/// JSON-encoding it, a crafted value could break out of the string literal
/// and run attacker JS in the fresh isolated site's context.
///
/// These tests feed a break-out payload through every string-interpolating
/// shim builder and assert the value only ever appears as a properly encoded
/// JS string literal. A future edit that swaps `jsonEncode(x)` for `$x`
/// fails here.
void main() {
  // A payload that, interpolated raw into `var x = "PAYLOAD";`, would close
  // the string and start a new statement. Includes a quote, statement break,
  // backslash, CRLF, a </script> sequence, and the JS line separators
  // (U+2028/U+2029) that pre-ES2019 engines treated as string terminators.
  const payload =
      'x"; window.__ws_pwned = 1; var y = "\\\r\n</script>  ';

  // The encoded form is the safe embedding: a valid JS string literal with
  // the quote, backslash and control chars escaped.
  final encoded = jsonEncode(payload);

  // The payload's unique marker. It legitimately appears once, inside the
  // encoded literal. If it appears ANYWHERE ELSE, the value escaped its
  // string context — a real break-out.
  const marker = '__ws_pwned';

  void expectNoBreakout(String shim, String label) {
    expect(shim.contains(encoded), isTrue,
        reason: '$label must embed the value as a jsonEncode()d literal');
    // Remove the (safe) encoded literal; the marker must not survive.
    final remainder = shim.replaceAll(encoded, '');
    expect(remainder.contains(marker), isFalse,
        reason: '$label leaked the value outside its JS string literal');
  }

  test('language shim json-encodes the language tag', () {
    expectNoBreakout(buildLanguageShim(payload), 'buildLanguageShim');
  });

  test('location shim json-encodes the spoofed timezone', () {
    final shim = LocationSpoofService.buildScript(
      locationMode: LocationMode.spoof,
      spoofLatitude: 40.0,
      spoofLongitude: -74.0,
      spoofAccuracy: 25.0,
      spoofTimezone: payload,
      webRtcPolicy: WebRtcPolicy.defaultPolicy,
    );
    expect(shim, isNotNull);
    expectNoBreakout(shim!, 'LocationSpoofService.buildScript');
  });

  test('anti-fingerprinting shim json-encodes the seed', () {
    expectNoBreakout(
        buildAntiFingerprintingShim(payload), 'buildAntiFingerprintingShim');
  });

  test('desktop-mode shim never emits the raw user-agent string', () {
    // The UA is only classified into a fixed platform token; its raw text
    // must never reach the injected JS. Feed a UA carrying the payload and
    // assert none of it (encoded or raw) appears in the output.
    final shim = buildDesktopModeShim(
        'Mozilla/5.0 (X11; Linux x86_64; $payload) Firefox/151.0');
    expect(shim.contains(marker), isFalse,
        reason: 'raw user-agent text must not reach desktop-mode shim JS');
  });

  test('ua-identity shim never emits the raw user-agent string', () {
    // Only the engine-derived constants (vendor/oscpu/...) reach the JS; the
    // UA text is classified, never interpolated. A Gecko-shaped UA carrying
    // the payload must yield a shim with no trace of it.
    final shim = buildUserAgentIdentityShim(
        'Mozilla/5.0 (Android 16; Mobile; rv:151.0; $payload) '
        'Gecko/151.0 Firefox/151.0');
    expect(shim, isNotNull);
    expect(shim!.contains(marker), isFalse,
        reason: 'raw user-agent text must not reach ua-identity shim JS');
  });
}
