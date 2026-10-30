// The Android desktop tier (INTEG-018; NAV-019), run on an Android desktop
// emulator by scripts/run_android_desktop_tests.sh, in the android-tv job
// after the TV's. A keyboard's keys go into the activity as Android delivers
// them (KeyboardInputPlugin's debug-only `debugTypeKey`), so each one takes
// the real path: FlutterView first, then, where Flutter hands it back, the
// System WebView inside it.
//
// It asserts what only a desktop window shows: that the app knows a keyboard
// and a pointer drive it, not a remote; that it is laid out once under the
// window's header; that Control asks for the shortcuts; and that a page with
// focus takes the arrows and Tab that Flutter would spend on its own focus.
//
// Everything here needs the desktop's own answers, so off the desktop tier
// (WS_DESKTOP_TIER unset: the phone and TV emulators, the desktop jobs that
// run every file) it skips.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/services/keyboard_input.dart';
import 'package:webspace/services/keyboard_shortcuts.dart';
import 'package:webspace/services/page_focus.dart';
import 'package:webspace/services/remote_input.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'package:webspace/settings/site_ids.dart';
import 'package:webspace/widgets/caption_tint.dart';
import 'package:webspace/widgets/shortcut_label.dart';
import 'bare_site.dart';
import 'fixture_server.dart';

const _desktopTier = bool.fromEnvironment('WS_DESKTOP_TIER');

const _keyboard = MethodChannel('org.codeberg.theoden8.webspace/keyboard_input');
const _caption = MethodChannel('org.codeberg.theoden8.webspace/window_caption');

// android.view.KeyEvent's codes and meta states.
const _keyT = 48;
const _keyQ = 45;
const _keyTab = 61;
const _keyLeft = 21;
const _metaCtrl = 0x1000 | 0x2000;

// android.view.WindowInsetsController's appearance flags.
const _transparentCaption = 1 << 7;
const _lightCaption = 1 << 8;

/// Two fields, the first holding text, so a Left moves its caret and a Tab
/// moves to the second.
const _formPage = '''
<!doctype html><html><head>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>body{margin:0;font:24px sans-serif} input{display:block;margin:24px;font:24px sans-serif}</style>
</head><body>
<input id="first" value="hello">
<input id="second">
</body></html>''';

const _probeJs = '''
JSON.stringify({
  ready: document.readyState,
  focused: document.hasFocus(),
  active: document.activeElement ? (document.activeElement.id || document.activeElement.tagName) : null,
  caret: document.activeElement && 'selectionStart' in document.activeElement ? document.activeElement.selectionStart : null
})''';

const _caretAtEndJs = '''
(function() {
  var f = document.getElementById('first');
  f.focus();
  f.setSelectionRange(f.value.length, f.value.length);
  return f.selectionStart;
})()''';

/// The page answers the shortcuts by recording them.
class _Screen implements ShortcutScreen {
  final asked = <KeyboardShortcut>[];

  @override
  bool get onTop => true;

  @override
  bool answerShortcut(KeyboardShortcut shortcut) {
    asked.add(shortcut);
    return true;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String page;

  setUpAll(() async {
    if (!_desktopTier) return;
    await bareSetUp();
    await RemoteInput.probe();
    await KeyboardInput.probe();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    page = 'http://127.0.0.1:${server.port}/form';
    listenFixture(server, onEvent: (request) {
      request.response
        ..headers.contentType = ContentType.html
        ..write(_formPage);
      unawaited(request.response.close());
    });
  });

  tearDownAll(() async {
    if (!_desktopTier) return;
    await server.close(force: true);
  });

  void log(String message) {
    // ignore: avoid_print
    print('android_desktop_test: $message');
  }

  Future<void> type(
    WidgetTester tester, {
    required int keyCode,
    int metaState = 0,
  }) async {
    await tester.runAsync(() async {
      await _keyboard.invokeMethod<void>(
          'debugTypeKey', {'keyCode': keyCode, 'metaState': metaState});
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await tester.pump();
  }

  testWidgets(
    'a desktop knows a keyboard and a pointer drive it, not a remote '
    '(INTEG-018, NAV-019)',
    (tester) async {
      log('remote: ${RemoteInput.driven}, keyboard: ${KeyboardInput.attached.value}');
      expect(RemoteInput.driven, isFalse,
          reason: 'a mouse stands in for a touchscreen, so the TV\'s '
              'D-pad answers (NAV-016) do not apply');
      expect(KeyboardInput.attached.value, isTrue,
          reason: 'the desktop emulator has a hardware keyboard');
      expect(PageKeys.host, PageKeys.keyboard);
    },
    skip: !_desktopTier,
  );

  testWidgets(
    'the app is laid out once under the window\'s header, whose buttons '
    'follow the app\'s brightness (INTEG-018, NAV-019)',
    (tester) async {
      Future<Map<String, int>> layout() async {
        Map<String, int> out = const {};
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          final raw = await _caption.invokeMapMethod<String, int>('debugLayout');
          out = raw ?? const {};
        });
        return out;
      }

      for (final mode in [ThemeMode.dark, ThemeMode.light]) {
        await tester.pumpWidget(MaterialApp(
          theme: ThemeData(brightness: Brightness.light),
          darkTheme: ThemeData(brightness: Brightness.dark),
          themeMode: mode,
          builder: (context, child) => CaptionTint(child: child!),
          home: Scaffold(appBar: AppBar(title: const Text('header'))),
        ));
        await tester.pumpAndSettle();
        final window = await layout();
        final view = tester.view;
        log('$mode: $window, padding top ${view.padding.top}');
        final caption = window['captionTop'] ?? 0;
        expect(caption, greaterThan(0),
            reason: 'the app opened full screen, not in a desktop window');
        expect(window['contentTop'], 0,
            reason: 'laid out below the header, the app would be padded '
                'for it a second time');
        expect((view.padding.top - caption).abs(), lessThanOrEqualTo(1),
            reason: 'the top padding is the header\'s, once');
        final appearance = window['appearance'] ?? 0;
        expect(appearance & _transparentCaption, isNot(0));
        expect(appearance & _lightCaption != 0, mode == ThemeMode.light,
            reason: 'dark buttons over a light app, light over a dark one');
      }
    },
    skip: !_desktopTier,
  );

  testWidgets(
    'Control asks for the shortcuts, Ctrl-Q for none, and the menus write '
    'the keys (INTEG-018, NAV-019)',
    (tester) async {
      final screen = _Screen();
      final keys = KeyboardShortcuts(screen)..start();
      addTearDown(keys.dispose);
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));

      await type(tester, keyCode: _keyT, metaState: _metaCtrl);
      log('after Ctrl-T: ${screen.asked}');
      expect(screen.asked.single, isA<OpenNewTab>());

      await type(tester, keyCode: _keyQ, metaState: _metaCtrl);
      expect(screen.asked, hasLength(1),
          reason: 'an Android app does not quit itself');

      expect(shortcutLabel<OpenNewTab>(const DefaultMaterialLocalizations()),
          'Ctrl+T');
    },
    skip: !_desktopTier,
  );

  testWidgets(
    'a page with focus takes the arrows and Tab, and Tab into it gives the '
    'webview focus (INTEG-018, NAV-019)',
    (tester) async {
      final bar = FocusNode(debugLabel: 'app bar');
      addTearDown(bar.dispose);
      WebViewController? controller;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              TextButton(
                focusNode: bar,
                onPressed: () {},
                child: const Text('app bar'),
              ),
              Expanded(
                child: WebViewFactory.createWebView(
                  config: WebViewConfig(
                    cacheFirst: false,
                    hooks: bareHooks(),
                    key: ValueKey(page),
                    posture: barePosture(page, siteId: SiteId('android-desktop')),
                    initialUrl: page,
                  ),
                  onControllerCreated: (c) => controller = c,
                ),
              ),
            ],
          ),
        ),
      ));

      Future<Map<String, dynamic>?> probe() async {
        Map<String, dynamic>? out;
        await tester.runAsync(() async {
          try {
            final raw = await controller
                ?.evaluateJavascriptReturning(_probeJs)
                .timeout(const Duration(seconds: 5));
            if (raw == null) return;
            final decoded = jsonDecode(raw is String ? raw : '$raw');
            if (decoded is Map<String, dynamic>) out = decoded;
          } on TimeoutException {
            // The bridge is not up yet; the caller asks again.
          } on FormatException {
            // Not the probe's JSON yet.
          }
        });
        return out;
      }

      Map<String, dynamic>? state;
      for (var i = 0; i < 90 && state?['ready'] != 'complete'; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 500)));
        await tester.pump();
        state = await probe();
      }
      expect(state?['ready'], 'complete', reason: 'the page never loaded');

      bar.requestFocus();
      await tester.pump();
      await type(tester, keyCode: _keyTab);
      expect(bar.hasFocus, isFalse, reason: 'Tab from the app bar enters the page');
      for (var i = 0; i < 10 && state?['focused'] != true; i++) {
        await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 300)));
        state = await probe();
      }
      log('entered: $state');
      expect(state?['focused'], isTrue,
          reason: 'the webview takes native focus as Flutter focus enters it '
              'from the keyboard');

      await tester.runAsync(() async {
        await controller?.evaluateJavascriptReturning(_caretAtEndJs);
      });
      await type(tester, keyCode: _keyLeft);
      state = await probe();
      log('after Left: $state');
      expect(state?['active'], 'first');
      expect(state?['caret'], 4, reason: 'Left moved the field\'s caret');

      await type(tester, keyCode: _keyTab);
      state = await probe();
      log('after Tab: $state');
      expect(state?['active'], 'second', reason: 'Tab moved to the next field');
      expect(bar.hasFocus, isFalse, reason: 'the page keeps Tab');
    },
    skip: !_desktopTier,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
