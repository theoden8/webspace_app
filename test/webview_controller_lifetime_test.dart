import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/capture_fakes.dart';
import 'helpers/mock_cookie_manager.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';

/// The native controller as the plugin hands it over: records every call that
/// reaches the platform and fails them the way [failWith] says.
class _NativeController implements inapp.InAppWebViewController {
  final List<String> calls = [];
  Object? failWith;

  /// What a cookie call reads to find the view's jar: a view the platform
  /// has no id for.
  @override
  inapp.PlatformInAppWebViewController get platform => _UnregisteredView();

  // A completed Future<Null> passes for every Future<T?> the factory awaits.
  // ignore: prefer_void_to_null
  Future<Null> _call(String name) async {
    calls.add(name);
    if (failWith case final error?) throw error;
    return null;
  }

  @override
  Future<void> reload() => _call('reload');

  @override
  Future<void> loadUrl({
    required inapp.URLRequest urlRequest,
    Uri? iosAllowingReadAccessTo,
    inapp.WebUri? allowingReadAccessTo,
  }) =>
      _call('loadUrl');

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    inapp.ContentWorld? contentWorld,
  }) =>
      _call('evaluateJavascript');

  @override
  Future<void> clearSslPreferences() => _call('clearSslPreferences');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isMethod ? Future<Null>.value() : null;
}

class _UnregisteredView extends Fake
    implements inapp.PlatformInAppWebViewController {
  @override
  dynamic get id => null;
}

final _site = WebViewModel(initUrl: 'https://example.com/');

/// A host that answers nothing: these tests never reach a prompt.
WebViewHostHooks _hooks({CookieManager? cookies}) => WebViewHostHooks(
      cookieManager: cookies ?? CookieManager(),
      containerCookieManager: null,
      globalUserScripts: () => const [],
      save: () async {},
      rebuild: () {},
      onScreen: (_) => true,
      launchNested: (_, {required posture, homeTitle}) {},
      openInBrowser: (_) async => false,
      routeOutbound:
          (_, {required url, required decision, required hadGesture}) => false,
      linkMenu: (_, {required url}) {},
      openSiteSettings: (_) {},
      showPopup: (_, {required url}) async {},
      externalScheme: (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, {required port, required certificate}) async =>
          false,
      httpAuth: (_) async => null,
      media: FakePrompter(),
    );

Widget _webView({
  Key? key,
  String? initialHtml,
  VoidCallback? onReloadIssued,
  void Function(WebViewController)? onControllerCreated,
  WebViewHostHooks? hooks,
  void Function(List<Cookie>)? onCookiesChanged,
  void Function(String url, {required String html})? onHtmlLoaded,
}) =>
    MaterialApp(
      home: WebViewFactory.createWebView(
        config: WebViewConfig(
          key: key,
          posture:
              _site.sitePosture(globalUserScripts: const <UserScriptConfig>[]),
          hooks: hooks ?? _hooks(),
          initialUrl: 'https://example.com/',
          initialHtml: initialHtml,
          onReloadIssued: onReloadIssued,
          onCookiesChanged: onCookiesChanged,
          onHtmlLoaded: onHtmlLoaded,
        ),
        onControllerCreated: onControllerCreated ?? (_) {},
      ),
    );

/// The platform's half of a webview coming up: the callbacks it was built
/// with, and the native controller it hands them.
Future<({inapp.PlatformInAppWebViewWidgetCreationParams params,
        _NativeController native})>
    _attach(WidgetTester tester) async {
  final view =
      tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
  final native = _NativeController();
  await tester.runAsync(() async {
    view.platform.params.onWebViewCreated!(native);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
  native.calls.clear();
  return (params: view.platform.params, native: native);
}

void main() {
  setUp(() {
    AndroidInAppWebViewPlatform.registerWith();
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async => call.method == 'create' ? 0 : null,
        );
  });
  tearDown(ConnectivityService.reset);

  testWidgets('a failed live-swap reload is the reload\'s own failure',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);
    var reloads = 0;
    await tester.pumpWidget(_webView(
      initialHtml: '<p>cached</p>',
      onReloadIssued: () => reloads++,
    ));
    final (:params, :native) = await _attach(tester);
    native.failWith = PlatformException(code: 'reload');
    await tester.runAsync(() async {
      params.onLoadStop!(native, inapp.WebUri('https://example.com/'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(native.calls, contains('reload'));
    expect(reloads, 1);
  });

  group('a cookie jar that fails (ISO-014, CONT-009)', () {
    testWidgets(
        'ISO-014: a cookie read that fails after a load leaves the mirror '
        'alone and the load finishes', (tester) async {
      final jar = MockCookieManager()..failing.add(JarCall.read);
      final mirrored = <List<Cookie>>[];
      await tester.pumpWidget(_webView(
        hooks: _hooks(cookies: jar),
        onCookiesChanged: mirrored.add,
        onHtmlLoaded: (_, {required html}) {},
      ));
      final (:params, :native) = await _attach(tester);
      await tester.runAsync(() async {
        params.onLoadStop!(native, inapp.WebUri('https://example.com/'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(mirrored, isEmpty,
          reason: 'a read that failed is not an empty jar to mirror');
      expect(native.calls, contains('evaluateJavascript'),
          reason: 'the page snapshot after the read is still asked for');
    });

    testWidgets(
        'CONT-009: a container jar read that fails throws, not an empty list',
        (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      await _attach(tester);
      await tester.runAsync(() async {
        // No handler on the cookie channel here, as in an engine the plugin
        // is not registered in.
        await expectLater(
            ContainerCookieManager().getCookies(
                controller: controller,
                url: Uri.parse('https://example.com/')),
            throwsA(isA<CookieJarFailure>()));
      });
    });

    test(
        'ISO-014: a blocked cookie the jar refuses to delete leaves the rest '
        'to go', () async {
      final jar = MockCookieManager();
      final url = Uri.parse('https://example.com/');
      for (final name in ['_ga', '_gid']) {
        await jar.setCookie(url: url, name: name, value: 'v');
      }
      jar.refusing.add('_ga');
      await _hooks(cookies: jar).removeBlockedCookies(
        [...jar.all],
        controller: null,
        url: url,
      );
      expect(jar.all.map((c) => c.name), ['_ga'],
          reason: 'the next load takes _ga; _gid is gone now');
    });
  });

  group('the controller over a native webview', () {
    testWidgets('reaches the platform while its webview is in the tree',
        (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      final (params: _, :native) = await _attach(tester);
      await tester.runAsync(() async {
        expect(await controller.reload(), isTrue);
        await controller.loadUrl('https://example.com/a');
        await controller.evaluateJavascript('1');
      });
      expect(native.calls, ['reload', 'loadUrl', 'evaluateJavascript']);
    });

    testWidgets('is a no-op once its webview has left the tree',
        (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      final (params: _, :native) = await _attach(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(() async {
        expect(await controller.reload(), isFalse);
        await controller.loadUrl('https://example.com/a');
        await controller.evaluateJavascript('1');
        expect(await controller.getUrl(), isNull);
      });
      expect(native.calls, isEmpty,
          reason: 'the plugin has disposed the native controller; a call on '
              'it asserts in debug');
    });

    testWidgets('is a no-op once a rebuilt webview has replaced it',
        (tester) async {
      final controllers = <WebViewController>[];
      await tester.pumpWidget(_webView(
          key: UniqueKey(), onControllerCreated: controllers.add));
      final (params: _, :native) = await _attach(tester);
      final replaced = controllers.last;
      await tester.pumpWidget(_webView(
          key: UniqueKey(), onControllerCreated: controllers.add));
      await tester.runAsync(() async {
        expect(await replaced.reload(), isFalse);
      });
      expect(native.calls, isEmpty);
    });

    testWidgets('reads a platform refusal as nothing happened',
        (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      final (params: _, :native) = await _attach(tester);
      await tester.runAsync(() async {
        native.failWith = PlatformException(code: 'refused');
        expect(await controller.reload(), isFalse);
        native.failWith = MissingPluginException();
        expect(await controller.reload(), isFalse);
        native.failWith = UnimplementedError('not on this platform');
        expect(await controller.reload(), isFalse);
      });
    });

    testWidgets(
        'reads a platform without an SSL preferences table as not cleared, '
        'so a pin revoke goes on to wipe the site (BUG-026)', (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      final (params: _, :native) = await _attach(tester);
      await tester.runAsync(() async {
        expect(await controller.clearSslPreferences(), isTrue);
        // What the plugin answers on iOS, macOS and Linux.
        native.failWith = UnimplementedError(
            'clearSslPreferences is not implemented on the current platform');
        expect(await controller.clearSslPreferences(), isFalse);
      });
      expect(native.calls, ['clearSslPreferences', 'clearSslPreferences']);
    });

    testWidgets('lets an Error through', (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      final (params: _, :native) = await _attach(tester);
      native.failWith = StateError('a bug');
      await tester.runAsync(() async {
        await expectLater(controller.reload(), throwsStateError);
      });
    });
  });
}
