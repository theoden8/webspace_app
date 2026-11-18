import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/outbound_http_types.dart' show OutboundProxy;
import 'package:webspace/services/media_session_service.dart';
import 'package:webspace/controllers/let_go_table.dart';
import 'package:webspace/controllers/site_runtime.dart';
import 'package:webspace/services/step_table.dart';
import 'package:webspace/web_view_model.dart';
import 'helpers/fake_webview_controller.dart';
import 'package:webspace/services/webview_controller.dart';

void main() {
  group('a renderer gone lets the webview go (LetGoTable)', () {
    /// [model] listed, loaded and built for its active tab, as a frame
    /// leaves it.
    SiteRuntime built(WebViewModel model) {
      final sites = SiteRuntime()..models.add(model);
      sites.seed(loaded: [model], shown: model);
      model.tabBinding.frame(model.activeTabId, commit: const Commit.fixture());
      model.webview = const SizedBox.shrink();
      model.controller = FakeWebViewController();
      return sites;
    }

    test('a loaded site: its webview, its controller and its tab go', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      final sites = built(model);

      LetGoTable.letGo(sites, site: model, end: WebViewEnd.rendererGone);

      expect(model.webview, isNull,
          reason: 'Cached widget must be cleared so the next getWebView call '
              'constructs a fresh InAppWebView.');
      expect(model.controller, isNull,
          reason: 'The dead controller is unusable — keep it and the next '
              'pause/resume/setSettings call hits a torn-down platform view.');
      expect(model.tabBinding.built, isNull,
          reason: 'the model lets go of built and hist (LetGo)');
      expect(sites.loaded, [model], reason: 'the site stays loaded');
    });

    test('a site the model takes no let-go of writes none of it', () {
      // Not loaded, nothing built: the teardown runs in Commit.none, which
      // fails on a write of the model.
      final model = WebViewModel(initUrl: 'https://example.com');
      final sites = SiteRuntime()..models.add(model);
      model.webview = const SizedBox.shrink();
      model.controller = FakeWebViewController();

      LetGoTable.letGo(sites, site: model, end: WebViewEnd.rendererGone);

      expect(model.webview, isNull);
      expect(model.controller, isNull);
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
        proxy: OutboundProxy.app,
      );
      expect(MediaSessionService.instance.isActive, isTrue);

      LetGoTable.letGo(SiteRuntime()..models.add(model),
          site: model, end: WebViewEnd.rendererGone);
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
