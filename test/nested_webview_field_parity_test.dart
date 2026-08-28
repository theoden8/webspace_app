import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:webspace/screens/inappbrowser.dart';
import 'package:webspace/settings/camera.dart';
import 'package:webspace/settings/microphone.dart';
import 'package:webspace/web_view_model.dart';

/// A per-site field that is applied by the parent webview but never threaded
/// into `InAppWebViewScreen` is a silent hole: one tap on an outbound link
/// drops the user's posture for the rest of that browsing session, inside the
/// parent's own container. `blockAutoRedirects`, `blockedCookies`, the
/// camera/microphone modes and their sources, and `protectedContentAllowed`
/// were all in `WebViewModel.toJson` and in the parent's `WebViewConfig` yet
/// missing from the nested chain.
///
/// `LaunchUrlFunc` is the single declaration of that chain, so this gate reads
/// its parameters and requires each one to survive every remaining step —
/// CLAUDE.md, "Per-site settings MUST apply to nested webviews".
String _read(String relative) => File(relative).readAsStringSync();

/// Text between [open] and the next [close], exclusive of both. Throws rather
/// than asserting so it can run while the test list is still being built.
String _blockBetween(String source, String open, String close) {
  final start = source.indexOf(open);
  if (start < 0) throw StateError('could not find "$open"');
  final bodyStart = start + open.length;
  final end = source.indexOf(close, bodyStart);
  if (end < 0) throw StateError('could not find "$close" after "$open"');
  return source.substring(bodyStart, end);
}

/// Named-parameter identifiers declared one per line, the shape used by the
/// typedef and by `launchUrl`.
Set<String> _namedParams(String block) {
  final pattern =
      RegExp(r'^\s*(?:required\s+)?[A-Za-z_][\w<>?, ]*\s+([a-z]\w*)\s*(?:=[^,]+)?,\s*$');
  return {
    for (final line in block.split('\n'))
      if (pattern.firstMatch(line) != null) pattern.firstMatch(line)!.group(1)!,
  };
}

void main() {
  final model = _read('lib/web_view_model.dart');
  final host = _read('lib/main.dart');
  final nested = _read('lib/screens/inappbrowser.dart');

  final chainFields = _namedParams(
    _blockBetween(model, 'typedef LaunchUrlFunc = void Function(', '});'),
  );

  test('the typedef is the whole per-site chain, not a stub', () {
    // Guards the parser itself: a regex that silently matched nothing would
    // make every assertion below vacuous.
    expect(chainFields.length, greaterThan(25));
    expect(
      chainFields,
      containsAll(<String>[
        'blockAutoRedirects',
        'blockedCookies',
        'cameraMode',
        'virtualCameraSource',
        'microphoneMode',
        'virtualMicrophoneSource',
        'protectedContentAllowed',
      ]),
    );
  });

  test('every chain field is a named parameter of launchUrl', () {
    final launchUrlParams = _namedParams(
      _blockBetween(host, 'Future<void> launchUrl(String url, {', '}) async {'),
    );
    expect(
      chainFields.difference(launchUrlParams),
      isEmpty,
      reason: 'lib/main.dart launchUrl dropped these per-site fields',
    );
  });

  test('every chain field is a constructor parameter of InAppWebViewScreen', () {
    final ctor = _blockBetween(nested, 'InAppWebViewScreen({', '  })');
    for (final field in chainFields) {
      expect(
        RegExp('\\b$field\\b').hasMatch(ctor),
        isTrue,
        reason: 'InAppWebViewScreen ctor does not accept "$field"',
      );
    }
  });

  test('every chain field is consumed by the nested screen, not just stored',
      () {
    for (final field in chainFields) {
      expect(
        nested.contains('widget.$field'),
        isTrue,
        reason: 'lib/screens/inappbrowser.dart accepts "$field" but never '
            'reads it — the field is declared and then dropped',
      );
    }
  });

  test('the four newly-threaded fields land on the widget', () {
    const source = VirtualCameraSource(
      kind: 'image',
      dataUrl: 'data:image/png;base64,AA==',
      fileName: 'cam.png',
    );
    const micSource = VirtualMicrophoneSource(
      dataUrl: 'data:audio/mp4;base64,AA==',
      fileName: 'mic.m4a',
    );
    final screen = InAppWebViewScreen(
      url: 'https://nested.example/',
      incognito: false,
      thirdPartyCookiesEnabled: false,
      clearUrlEnabled: true,
      dnsBlockEnabled: true,
      contentBlockEnabled: true,
      localCdnEnabled: true,
      trackingProtectionEnabled: true,
      language: 'en',
      blockAutoRedirects: true,
      blockedCookies: {const BlockedCookie(name: 'sid', domain: 'ads.example')},
      cameraMode: CameraAccessMode.block,
      virtualCameraSource: source,
      microphoneMode: MicrophoneAccessMode.virtual,
      virtualMicrophoneSource: micSource,
      protectedContentAllowed: false,
    );

    expect(screen.blockAutoRedirects, isTrue);
    expect(screen.blockedCookies.single.name, equals('sid'));
    expect(screen.cameraMode, equals(CameraAccessMode.block));
    expect(screen.virtualCameraSource, same(source));
    expect(screen.microphoneMode, equals(MicrophoneAccessMode.virtual));
    expect(screen.virtualMicrophoneSource, same(micSource));
    expect(screen.protectedContentAllowed, isFalse);
  });

  test('defaults stay inert so an un-threaded caller changes nothing', () {
    final screen = InAppWebViewScreen(
      url: 'https://nested.example/',
      incognito: false,
      thirdPartyCookiesEnabled: false,
      clearUrlEnabled: true,
      dnsBlockEnabled: true,
      contentBlockEnabled: true,
      localCdnEnabled: true,
      trackingProtectionEnabled: true,
      language: 'en',
    );

    expect(screen.blockAutoRedirects, isFalse);
    expect(screen.blockedCookies, isEmpty);
    expect(screen.cameraMode, equals(CameraAccessMode.ask));
    expect(screen.microphoneMode, equals(MicrophoneAccessMode.ask));
    expect(screen.protectedContentAllowed, isNull);
  });
}
