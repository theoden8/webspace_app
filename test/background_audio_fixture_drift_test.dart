import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../integration_test/fixtures/background_audio_fixture.dart';

/// BGAUDIO-005: the loopback server in the background-audio integration test
/// serves [backgroundAudioFixtureHtml] (the sandboxed test app cannot read
/// repo files at runtime on macOS CI), while
/// `integration_test/fixtures/background_audio.html` stays the authoritative,
/// browser-openable fixture. This host-side test pins the two together so an
/// edit to either cannot silently diverge — same shape as
/// `test/js_fixtures_drift_test.dart`.
void main() {
  test('embedded background-audio fixture matches the .html on disk', () {
    final file = File('integration_test/fixtures/background_audio.html');
    expect(file.existsSync(), isTrue,
        reason: 'authoritative fixture missing at ${file.path}');
    expect(backgroundAudioFixtureHtml, file.readAsStringSync(),
        reason: 'integration_test/fixtures/background_audio_fixture.dart has '
            'drifted from background_audio.html — update both together');
  });
}
