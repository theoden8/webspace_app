import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/web_view_model.dart';
import 'helpers/fake_webview_controller.dart';
import 'package:webspace/services/webview_controller.dart';

void main() {
  group('WebViewModel.handleRendererGone', () {
    test('clears cached webview + controller and triggers a rebuild', () {
      var rebuilds = 0;
      final model = WebViewModel(
        initUrl: 'https://example.com',
        stateSetterF: () => rebuilds++,
      );
      model.webview = const SizedBox.shrink();
      model.controller = FakeWebViewController();

      model.handleRendererGone(didCrash: true);

      expect(model.webview, isNull,
          reason: 'Cached widget must be cleared so the next getWebView call '
              'constructs a fresh InAppWebView.');
      expect(model.controller, isNull,
          reason: 'The dead controller is unusable — keep it and the next '
              'pause/resume/setSettings call hits a torn-down platform view.');
      expect(rebuilds, 1,
          reason: 'Host must rebuild so the IndexedStack child reconstructs.');
    });

    test('handles a null stateSetterF without throwing', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.webview = const SizedBox.shrink();
      model.controller = FakeWebViewController();

      expect(() => model.handleRendererGone(didCrash: false), returnsNormally);
      expect(model.webview, isNull);
      expect(model.controller, isNull);
    });

    test('didCrash=false (OS-killed renderer) still recreates', () {
      // Per Android docs: when didCrash is false the renderer was killed by
      // the system to reclaim memory. The recovery is the same as a hard
      // crash — the WebView object is unusable either way.
      var rebuilds = 0;
      final model = WebViewModel(
        initUrl: 'https://example.com',
        stateSetterF: () => rebuilds++,
      );
      model.webview = const SizedBox.shrink();
      model.controller = FakeWebViewController();

      model.handleRendererGone(didCrash: false);

      expect(model.webview, isNull);
      expect(model.controller, isNull);
      expect(rebuilds, 1);
    });
  });

  group('a renderer gone takes what its webview held', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    const channel =
        MethodChannel('org.codeberg.theoden8.webspace/media_session');
    late List<String> calls;

    setUp(() {
      calls = [];
      MediaSessionService.debugEnabledOverride = true;
      MediaSessionService.debugVisibilityCheckDelay = Duration.zero;
      MediaSessionService.debugSurfaceReclearDelay = Duration.zero;
      MediaSessionService.instance.debugReset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call.method);
            return call.method == 'isNotificationActive' ? true : null;
          });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
      MediaSessionService.debugEnabledOverride = null;
      MediaSessionService.debugVisibilityCheckDelay =
          const Duration(seconds: 1);
      MediaSessionService.instance.debugReset();
    });

    /// The player the controls spoke for died with the renderer, as it goes
    /// with a disposed webview, so its controls go too (BGAUDIO-010): left
    /// up, their buttons reach nothing until the reloaded page plays again.
    test('the media controls its page put up (BGAUDIO-010)', () async {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.webview = const SizedBox.shrink();
      model.controller = FakeWebViewController();
      await MediaSessionService.instance.report(
        model.siteId,
        page: const MediaSessionReport(
          frame: 'main',
          isMainFrame: true,
          playing: true,
          title: 'Track',
          artist: 'Artist',
          album: 'Album',
          artworkUrl: '',
        ),
        runJs: (_) async {},
        proxy: null,
      );
      expect(MediaSessionService.instance.isActive, isTrue);

      model.handleRendererGone(didCrash: true);
      await pumpEventQueue();

      expect(calls.where((m) => m != 'isNotificationActive'), ['start', 'stop']);
      expect(MediaSessionService.instance.isActive, isFalse);
    });
  });

  group('rendererProbeIndicatesGone', () {
    test('null result means the renderer process is gone', () {
      // evaluateJavascriptReturning maps a dead-process throw to null
      // (iOS WebContentProcessTerminated, Android renderer killed).
      expect(rendererProbeIndicatesGone(null), isTrue);
    });

    test('numeric results mean the renderer is alive', () {
      // Positive height (painted), 0 (about:blank), and -1 (document/body
      // not built yet, still loading) are all live renderers — recreating
      // on these would reload-loop a healthy page.
      expect(rendererProbeIndicatesGone(640), isFalse);
      expect(rendererProbeIndicatesGone(0), isFalse);
      expect(rendererProbeIndicatesGone(-1), isFalse);
      expect(rendererProbeIndicatesGone(12.5), isFalse);
    });
  });
}
