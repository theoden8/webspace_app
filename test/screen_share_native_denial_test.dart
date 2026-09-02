import 'dart:io';

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';

/// SHARE-003: no native path may ever hand a site a display surface.
///
/// Today that holds without any code in `onPermissionRequest`, because no
/// platform this app ships routes a display-capture request to Dart at all:
///
/// - **Android** — `WebChromeClient.onPermissionRequest` has resources for
///   audio, video, MIDI sysex and protected media. There is no display one,
///   and Android WebView implements no screen capture to gate.
/// - **iOS / macOS** — the plugin implements only
///   `requestMediaCapturePermissionFor`, whose `WKMediaCaptureType` is
///   camera / microphone / cameraAndMicrophone. WebKit's display-capture
///   delegate is not implemented, so WKWebView's default (deny) stands.
/// - **Linux (WPE)** — a display-device `WebKitUserMediaPermissionRequest`
///   maps to an EMPTY resource list, and the plugin denies an empty list
///   natively before Dart is consulted.
///
/// "It happens to be impossible" is not a guarantee, though: a fork bump that
/// adds a display resource type would silently start routing such a request
/// into `onPermissionRequest`, where the fallback returns PROMPT — which
/// iOS/macOS render as WebKit's own picker. This test fails on that bump so
/// the deny is written before the capability arrives, not after.
void main() {
  group('SHARE-003 — the platform cannot ask us to share a display', () {
    test('no PermissionResourceType names a display surface', () {
      // Substrings that would appear in a display-capture resource name. Kept
      // deliberately broad: the point is to catch a NEW value, not to match a
      // spelling we already know.
      const displayish = ['display', 'screen', 'desktop', 'monitor', 'window'];
      final offenders = <String>[];
      for (final type in inapp.PermissionResourceType.values) {
        final name = type.toNativeValue()?.toString() ?? type.toString();
        final haystack = '${type.toString()} $name'.toLowerCase();
        for (final needle in displayish) {
          // WINDOW_MANAGEMENT is the Multi-Screen Window Placement API
          // (where a page may open windows), not a capture surface.
          if (haystack.contains(needle) &&
              !haystack.contains('window_management')) {
            offenders.add('${type.toString()} (matched "$needle")');
            break;
          }
        }
      }
      expect(
        offenders,
        isEmpty,
        reason: 'The webview plugin now reports a display-capture permission '
            'resource: $offenders. Deny it explicitly in '
            "WebViewFactory's onPermissionRequest before this ships — the "
            'PROMPT fallback there becomes WebKit\'s own screen picker on '
            'iOS/macOS, which would hand the site the whole device screen '
            'including every other site in the webspace.',
      );
    });

    test('the only capture GRANT the app issues names one resource', () {
      // Read from the source rather than re-stated here: the invariant is
      // about what `onPermissionRequest` actually sends, and a test that
      // builds its own list proves nothing about it. If a display resource
      // ever rode along in that list, a camera Allow would widen into a
      // screen share (SHARE-004).
      final source = File('lib/services/webview.dart').readAsStringSync();
      final grants = RegExp(r'resources:\s*\[([^\]]*)\]')
          .allMatches(source)
          .map((m) => m.group(1)!.trim())
          .where((r) => r.contains('PermissionResourceType'))
          .toList();
      expect(grants, isNotEmpty,
          reason: 'no literal resource list found in onPermissionRequest');
      for (final list in grants) {
        expect(
          RegExp(r'PermissionResourceType\.').allMatches(list).length,
          1,
          reason: 'a capture response must name exactly one resource, got: '
              '$list',
        );
      }
    });
  });
}
