// Dumps each JS shim to test/js_fixtures/<group>/<variant>.js so Node-side
// tests can run the exact string the webview sees.
//
// Usage:
//   fvm dart run tool/dump_shim_js.dart           # writes fixtures
//   fvm dart run tool/dump_shim_js.dart --check   # exits 1 if anything drifts
//
// Add a new shim by:
//   1. Importing the builder.
//   2. Adding entries to [buildAllFixtures] — keyed by relative path under
//      test/js_fixtures/, valued at the shim string the builder returns for
//      that scenario.
//   3. Re-running this script to commit the new fixture(s).
//
// The companion Dart test test/js_fixtures_drift_test.dart re-invokes
// [buildAllFixtures] and compares against on-disk fixtures so a shim change
// without a fixture refresh fails locally and in CI.

import 'dart:io';

import 'package:webspace/services/blob_url_capture.dart';
import 'package:webspace/services/content_blocker_shim.dart';
import 'package:webspace/services/desktop_mode_shim.dart';
import 'package:webspace/services/language_shim.dart';
import 'package:webspace/services/location_spoof_service.dart';
import 'package:webspace/services/theme_color_scheme_shim.dart';
import 'package:webspace/services/user_agent_classifier.dart';
import 'package:webspace/settings/location.dart';

/// Build every fixture this script knows about. Map keys are paths relative
/// to [fixturesRoot]; values are the JS that should be on disk at that path.
Map<String, String> buildAllFixtures() {
  final fixtures = <String, String>{};

  fixtures['blob_url_capture/shim.js'] = blobUrlCaptureScript;
  // Pinned test triple — the Node-side test minds the polyfill so the
  // first createObjectURL call returns 'blob:https://example.test/test-blob-1',
  // matching the URL baked into this IIFE.
  fixtures['blob_url_capture/download_iife.js'] = buildBlobDownloadIife(
    blobUrl: 'blob:https://example.test/test-blob-1',
    suggestedFilename: 'hello.txt',
    taskId: 'task-fixture',
  );

  fixtures['desktop_mode/linux.js'] =
      buildDesktopModeShim(firefoxLinuxDesktopUserAgent);
  fixtures['desktop_mode/macos.js'] =
      buildDesktopModeShim(firefoxMacosDesktopUserAgent);
  fixtures['desktop_mode/windows.js'] =
      buildDesktopModeShim(firefoxWindowsDesktopUserAgent);

  fixtures['location_spoof/static_tokyo.js'] =
      LocationSpoofService.buildScript(
    locationMode: LocationMode.spoof,
    spoofLatitude: 35.6762,
    spoofLongitude: 139.6503,
    spoofAccuracy: 25.0,
    spoofTimezone: null,
    webRtcPolicy: WebRtcPolicy.defaultPolicy,
  )!;
  fixtures['location_spoof/timezone_only_tokyo.js'] =
      LocationSpoofService.buildScript(
    locationMode: LocationMode.off,
    spoofLatitude: null,
    spoofLongitude: null,
    spoofAccuracy: 50.0,
    spoofTimezone: 'Asia/Tokyo',
    webRtcPolicy: WebRtcPolicy.defaultPolicy,
  )!;
  fixtures['location_spoof/webrtc_relay.js'] =
      LocationSpoofService.buildScript(
    locationMode: LocationMode.off,
    spoofLatitude: null,
    spoofLongitude: null,
    spoofAccuracy: 50.0,
    spoofTimezone: null,
    webRtcPolicy: WebRtcPolicy.relayOnly,
  )!;
  fixtures['location_spoof/webrtc_disabled.js'] =
      LocationSpoofService.buildScript(
    locationMode: LocationMode.off,
    spoofLatitude: null,
    spoofLongitude: null,
    spoofAccuracy: 50.0,
    spoofTimezone: null,
    webRtcPolicy: WebRtcPolicy.disabled,
  )!;
  fixtures['location_spoof/full_combo.js'] = LocationSpoofService.buildScript(
    locationMode: LocationMode.spoof,
    spoofLatitude: 48.8566,
    spoofLongitude: 2.3522,
    spoofAccuracy: 30.0,
    spoofTimezone: 'Europe/Paris',
    webRtcPolicy: WebRtcPolicy.relayOnly,
  )!;

  fixtures['language/en.js'] = buildLanguageShim('en');
  fixtures['language/fr_FR.js'] = buildLanguageShim('fr-FR');
  fixtures['language/ja.js'] = buildLanguageShim('ja');

  fixtures['theme_color_scheme/light.js'] = buildThemeColorSchemeShim('light');
  fixtures['theme_color_scheme/dark.js'] = buildThemeColorSchemeShim('dark');
  fixtures['theme_color_scheme/system.js'] = buildThemeColorSchemeShim('system');

  // Content-blocker fixture inputs are a stand-in for what a real ABP
  // filter list produces — a mix of class selectors, attribute
  // selectors, and a text-match rule that catches sponsor content
  // whose markup doesn't carry a stable class.
  const sampleSelectors = [
    '.ad-banner',
    '.sponsored',
    '#sidebar-ad',
    'div[data-ad-slot]',
    'a[href*="track.example.com"]',
  ];
  const sampleTextRules = <ContentBlockerTextRule>[
    (selector: 'div.article > p', patterns: ['Sponsored content']),
  ];
  fixtures['content_blocker/early_css.js'] =
      buildContentBlockerEarlyCssShim(sampleSelectors)!;
  fixtures['content_blocker/cosmetic.js'] = buildContentBlockerCosmeticShim(
    selectors: sampleSelectors,
    textRules: sampleTextRules,
  )!;

  return fixtures;
}

/// Resolves to `<repo>/test/js_fixtures` regardless of CWD when invoked.
Directory get fixturesRoot {
  // tool/dump_shim_js.dart sits one level below the repo root.
  final scriptFile = File.fromUri(Platform.script);
  final repoRoot = scriptFile.parent.parent;
  return Directory('${repoRoot.path}/test/js_fixtures');
}

void main(List<String> args) {
  final check = args.contains('--check');
  final fixtures = buildAllFixtures();
  final root = fixturesRoot;

  var drift = 0;
  for (final entry in fixtures.entries) {
    final file = File('${root.path}/${entry.key}');
    final expected = entry.value;

    if (check) {
      if (!file.existsSync() || file.readAsStringSync() != expected) {
        stderr.writeln('drift: ${entry.key}');
        drift++;
      }
      continue;
    }

    file.parent.createSync(recursive: true);
    file.writeAsStringSync(expected);
    stdout.writeln('wrote ${entry.key} (${expected.length} bytes)');
  }

  if (check && drift > 0) {
    stderr.writeln(
        '\n$drift fixture(s) out of date. Run `fvm dart run tool/dump_shim_js.dart` to refresh.');
    exit(1);
  }
}
