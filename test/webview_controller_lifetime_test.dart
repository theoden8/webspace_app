import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/clearurl_service.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/container_cookie_manager.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/cookie_manager.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/file_import_document.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/capture_fakes.dart';
import 'helpers/fake_outbound.dart';
import 'helpers/fake_platform_controller.dart';
import 'helpers/mock_cookie_manager.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/services/webview_controller.dart';
import 'helpers/isolations.dart';

/// The native controller as the plugin hands it over: records every call that
/// reaches the platform and fails them the way [failWith] says.
class _NativeController implements inapp.InAppWebViewController {
  _NativeController({inapp.PlatformInAppWebViewController? platform})
      : platform = platform ?? FakePlatformController();

  /// The platform controller this wrapper is over; the plugin puts two
  /// wrappers over one.
  @override
  final inapp.PlatformInAppWebViewController platform;

  final List<String> calls = [];
  final List<inapp.URLRequest> requests = [];
  Object? failWith;

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
  }) {
    requests.add(urlRequest);
    return _call('loadUrl');
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    inapp.ContentWorld? contentWorld,
  }) =>
      _call('evaluateJavascript');

  /// Far past any id the platform-view registry hands out, so the plugin's
  /// own view, numbered by how many views earlier tests made, never shares it.
  static const viewId = 1 << 30;

  @override
  dynamic getViewId() => viewId;

  @override
  Future<void> loadData({
    required String data,
    String mimeType = 'text/html',
    String encoding = 'utf8',
    inapp.WebUri? baseUrl,
    Uri? androidHistoryUrl,
    inapp.WebUri? historyUrl,
    Uri? iosAllowingReadAccessTo,
    inapp.WebUri? allowingReadAccessTo,
  }) =>
      _call('loadData');

  @override
  Future<void> clearSslPreferences() => _call('clearSslPreferences');

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isMethod ? Future<Null>.value() : null;
}

final _site = WebViewModel(initUrl: 'https://example.com/');

/// A host that answers nothing, but for [externalScheme] when a test asks
/// what reached the prompt, its cookies kept apart by [isolation].
WebViewHostHooks _hooks({
  Future<void> Function(ExternalUrlInfo info,
          {required WebViewController? loadIn})?
      externalScheme,
  Isolation Function()? isolation,
}) =>
    WebViewHostHooks(
      isolation: isolation ?? fakeSharedJar,
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
      externalScheme: externalScheme ?? (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, {required port, required certificate}) async =>
          false,
      httpAuth: (_) async => null,
      media: FakePrompter(),
    );

Widget _webView({
  WebViewHostHooks? hooks,
  Key? key,
  bool cacheFirst = false,
  VoidCallback? onReloadIssued,
  void Function(WebViewController)? onControllerCreated,
  void Function(List<Cookie>)? onCookiesChanged,
}) =>
    MaterialApp(
      home: WebViewFactory.createWebView(
        config: WebViewConfig(
          key: key,
          posture:
              _site.sitePosture(
                  globalUserScripts: const <UserScriptConfig>[],
                  isolation: fakeSharedJar()),
          hooks: hooks ?? _hooks(),
          initialUrl: 'https://example.com/',
          cacheFirst: cacheFirst,
          onReloadIssued: onReloadIssued,
          onCookiesChanged: onCookiesChanged,
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

/// The policy a main-frame navigation to [url] gets in a fresh webview, a
/// tap unless [hasGesture] says not, and the calls it left on the native view.
Future<({inapp.NavigationActionPolicy? policy, List<String> calls})> _navigate(
  WidgetTester tester, {
  required String url,
  bool hasGesture = true,
  WebViewHostHooks? hooks,
}) async {
  await tester.pumpWidget(_webView(hooks: hooks));
  final (:params, :native) = await _attach(tester);
  final policy = await tester.runAsync(() async =>
      params.shouldOverrideUrlLoading!(
        native,
        // A gesture's navigation is a link the user activated, which the
        // platform vouches is the page's own (NESTED-013).
        inapp.NavigationAction(
          request: inapp.URLRequest(url: inapp.WebUri(url)),
          isForMainFrame: true,
          hasGesture: hasGesture,
          navigationType:
              hasGesture ? inapp.NavigationType.LINK_ACTIVATED : null,
        ),
      ));
  await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)));
  return (policy: policy, calls: native.calls);
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

  // The plugin hands onWebViewCreated one InAppWebViewController and every
  // later callback another, both over one platform controller: told apart by
  // the wrapper, every load callback read as a dead view's and was dropped.
  testWidgets('callbacks passing another wrapper over the view still act',
      (tester) async {
    // What main() loads before any page, as a load start asserts (CB-001).
    await tester.runAsync(() async {
      SharedPreferences.setMockInitialValues({});
      await ContentBlockerService.instance.initialize(native: WebInterceptNative.initialize());
    });
    addTearDown(ContentBlockerService.instance.reset);
    var settled = 0;
    await tester.pumpWidget(MaterialApp(
      home: WebViewFactory.createWebView(
        config: WebViewConfig(
          cacheFirst: false,
          posture:
              _site.sitePosture(
                  globalUserScripts: const <UserScriptConfig>[],
                  isolation: fakeSharedJar()),
          hooks: _hooks(),
          initialUrl: 'https://example.com/',
          onLoadingChanged: ({required loading}) {
            if (!loading) settled++;
          },
        ),
        onControllerCreated: (_) {},
      ),
    ));
    final params = tester
        .widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
        .platform
        .params;
    final created = _NativeController();
    final later = _NativeController(platform: created.platform);
    await tester.runAsync(() async {
      params.onWebViewCreated!(created);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      params.onLoadStart!(later, inapp.WebUri('https://example.com/'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      params.onLoadStop!(later, inapp.WebUri('https://example.com/'));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(settled, 1, reason: 'the load stop reached the page');
    final policy = await tester.runAsync(() async => params.shouldOverrideUrlLoading!(
          later,
          inapp.NavigationAction(
            request:
                inapp.URLRequest(url: inapp.WebUri('https://example.com/a')),
            isForMainFrame: true,
            hasGesture: true,
          ),
        ));
    await tester.pump(const Duration(seconds: 3));
    expect(policy, isNot(inapp.NavigationActionPolicy.CANCEL),
        reason: 'a navigation of the live view is not cancelled');
  });

  testWidgets('a failed live-swap reload is the reload\'s own failure',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);
    var reloads = 0;
    await tester.pumpWidget(_webView(
      cacheFirst: true,
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

  // A listed URL is judged before ClearURLs rewrites it (a rewrite reissues
  // the load) and before the captcha allow (CAPTCHA-008), so neither lets a
  // blocked host load.
  group('the blocklist judges a navigation first (DNS-008)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      await ContentBlockerService.instance
          .initialize(native: WebInterceptNative.initialize());
      DnsBlockService.instance.loadDomainsFromString(
          'tracker.example\nhcaptcha.com');
      ClearUrlService.instance.loadRulesFromJson({
        'providers': {
          'any': {
            'urlPattern': r'.*',
            'completeProvider': false,
            'rules': [r'^utm_source$'],
            'rawRules': [],
            'exceptions': [],
            'redirections': [],
          },
        },
      });
    });
    tearDown(() {
      ContentBlockerService.instance.reset();
      DnsBlockService.instance.resetForTest();
      ClearUrlService.instance.resetForTest();
    });

    testWidgets('a listed URL is cancelled before ClearURLs rewrites it',
        (tester) async {
      final fine =
          await _navigate(tester, url: 'https://fine.example/?utm_source=x');
      expect(fine.policy, inapp.NavigationActionPolicy.CANCEL);
      expect(fine.calls, contains('loadUrl'),
          reason: 'ClearURLs reissues an unlisted URL without the param');

      final listed =
          await _navigate(tester, url: 'https://tracker.example/?utm_source=x');
      expect(listed.policy, inapp.NavigationActionPolicy.CANCEL);
      expect(listed.calls, isNot(contains('loadUrl')),
          reason: 'a blocked URL is never reissued');
    });

    testWidgets('a listed captcha host is cancelled, not allowed in place',
        (tester) async {
      DnsBlockService.instance.loadDomainsFromString('tracker.example');
      expect((await _navigate(tester, url: 'https://hcaptcha.com/checkbox')).policy,
          inapp.NavigationActionPolicy.ALLOW,
          reason: 'the captcha allow, with the host off the list');

      DnsBlockService.instance.loadDomainsFromString('hcaptcha.com');
      expect((await _navigate(tester, url: 'https://hcaptcha.com/checkbox')).policy,
          inapp.NavigationActionPolicy.CANCEL);
    });

    testWidgets('no request waits on a Dart round trip', (tester) async {
      await tester.pumpWidget(_webView());
      final view =
          tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
      expect(view.platform.params.initialSettings?.useShouldInterceptRequest,
          isFalse);
    });
  });

  // A scheme with no web fallback goes to the host's prompt (EXT-004). The
  // loop guard for one that has one reads the gesture the way Android and
  // Apple report it, so this host cannot drive it.
  group('external schemes', () {
    testWidgets('a scheme with no web fallback goes to the prompt (EXT-004)',
        (tester) async {
      final asked = <String>[];
      final hooks = _hooks(
          externalScheme: (info, {required loadIn}) async =>
              asked.add(info.scheme));
      for (final url in [
        'intent://scan/#Intent;scheme=zxing;'
            'package=com.google.zxing.client.android;end',
        'tel:+14155551234',
      ]) {
        final r = await _navigate(tester, url: url, hooks: hooks);
        expect(r.policy, inapp.NavigationActionPolicy.CANCEL, reason: url);
        expect(r.calls, isNot(contains('loadUrl')), reason: url);
      }
      expect(asked, ['intent', 'tel']);
    });
  });

  // The fork makes a widget's initial load as it creates the native view,
  // before Dart hears of it, so on Android the first document's
  // sub-resources left before the interceptor attached.
  group('Android holds the first load until the interceptor attaches', () {
    const channel = MethodChannel('org.codeberg.theoden8.webspace/web_intercept');
    late Completer<bool> attach;
    late List<MethodCall> sent;
    setUp(() {
      WebInterceptNative.debugAssumeAndroid = true;
      attach = Completer<bool>();
      sent = [];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        sent.add(call);
        return call.method == 'attachToView' ? attach.future : null;
      });
    });
    tearDown(() {
      WebInterceptNative.debugAssumeAndroid = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<_NativeController> created(WidgetTester tester) async {
      final view =
          tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
      expect(view.platform.params.initialUrlRequest, isNull);
      expect(view.platform.params.initialData, isNull);
      final native = _NativeController();
      await tester.runAsync(() async {
        view.platform.params.onWebViewCreated!(native);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      return native;
    }

    testWidgets('the page\'s own URL', (tester) async {
      await tester.pumpWidget(_webView());
      final native = await created(tester);
      expect(native.calls, isNot(contains('loadUrl')));
      // The plugin under test also creates a view of its own (id 0).
      final attachCall = sent.singleWhere((c) =>
          c.method == 'attachToView' && (c.arguments as Map)['viewId'] == _NativeController.viewId);
      expect(attachCall.arguments, containsPair('siteId', _site.siteId));

      await tester.runAsync(() async {
        attach.complete(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(native.calls, contains('loadUrl'));
    });

    testWidgets('a cache-first load, which keeps its cache policy',
        (tester) async {
      ConnectivityService.onlineOverride = Future.value(true);
      await tester.pumpWidget(_webView(cacheFirst: true));
      final native = await created(tester);
      expect(native.calls, isNot(contains('loadUrl')));
      await tester.runAsync(() async {
        attach.complete(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      expect(native.requests.single.cachePolicy,
          inapp.URLRequestCachePolicy.RETURN_CACHE_DATA_ELSE_LOAD);
    });

    // The level a site follows can land after its view attached; the
    // view hears it, and stops hearing once it has left the tree.
    testWidgets('a level that lands later reaches the attached view',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final dns = DnsBlockService.instance
        ..resetForTest()
        ..store = MemoryFileStore();
      addTearDown(dns.resetForTest);
      await tester.pumpWidget(_webView());
      await created(tester);
      await tester.runAsync(() async {
        attach.complete(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      List<Object?> levels() => [
            for (final c in sent)
              if (c.method == 'attachToView' &&
                  (c.arguments as Map)['viewId'] == _NativeController.viewId)
                (c.arguments as Map)['dnsLevel'],
          ];
      expect(levels(), [0]);

      await tester.runAsync(() => dns.applyImportedLevel(3));
      expect(levels(), [0, 3]);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dns.applyImportedLevel(2));
      expect(levels(), [0, 3], reason: 'an unmounted view is not attached again');
    });

    // An app-wide download moves the level every site without its own
    // follows: the view is told once the new level is in force, not before.
    testWidgets('an app-wide download reaches the attached view',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final dns = DnsBlockService.instance
        ..resetForTest()
        ..store = MemoryFileStore();
      addTearDown(dns.resetForTest);
      final body = [for (var i = 0; i < 1200; i++) 'filler-$i.example']
          .join('\n');
      outboundHttp = FakeOutbound(
        responder: (req) => dnsMirrorUrlsForLevel(2).contains(req.url.toString())
            ? http.Response(body, 200)
            : http.Response('not found', 404),
      );
      addTearDown(resetOutboundHttp);
      await tester.pumpWidget(_webView());
      await created(tester);
      await tester.runAsync(() async {
        attach.complete(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      List<Object?> levels() => [
            for (final c in sent)
              if (c.method == 'attachToView' &&
                  (c.arguments as Map)['viewId'] == _NativeController.viewId)
                (c.arguments as Map)['dnsLevel'],
          ];
      expect(levels(), [0]);

      expect(await tester.runAsync(() => dns.downloadList(2)), isTrue);
      expect(levels(), [0, 2]);
    });

    // A popup is one of the site's views: a list that lands while it is
    // open reaches it too, and stops once it has closed.
    testWidgets('a level that lands later reaches the site\'s popup',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final dns = DnsBlockService.instance
        ..resetForTest()
        ..store = MemoryFileStore();
      addTearDown(dns.resetForTest);
      final config = WebViewConfig(
        cacheFirst: false,
        posture: _site.sitePosture(
            globalUserScripts: const <UserScriptConfig>[],
            isolation: fakeSharedJar()),
        hooks: _hooks(),
        initialUrl: 'https://example.com/',
      );
      await tester.pumpWidget(MaterialApp(
        home: PopupWebView.createPopupWebView(windowId: 1, config: config),
      ));
      final view =
          tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
      await tester.runAsync(() async {
        view.platform.params.onWebViewCreated!(_NativeController());
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      List<Object?> levels() => [
            for (final c in sent)
              if (c.method == 'attachToView' &&
                  (c.arguments as Map)['viewId'] == _NativeController.viewId)
                (c.arguments as Map)['dnsLevel'],
          ];
      expect(levels(), [0]);

      await tester.runAsync(() => dns.applyImportedLevel(3));
      expect(levels(), [0, 3]);

      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => dns.applyImportedLevel(2));
      expect(levels(), [0, 3], reason: 'a closed popup is not attached again');
    });

    // The filter lists are app-wide on the native side too, so the attach
    // is what keeps a site that switched them off from meeting them (CB-006).
    testWidgets('a site with its content blocker off attaches without the lists',
        (tester) async {
      SharedPreferences.setMockInitialValues({});
      final dns = DnsBlockService.instance
        ..resetForTest()
        ..store = MemoryFileStore();
      addTearDown(dns.resetForTest);
      final site = WebViewModel(
        initUrl: 'https://example.com/',
        contentBlockEnabled: false,
        trackingProtectionEnabled: false,
      );
      await tester.pumpWidget(MaterialApp(
        home: WebViewFactory.createWebView(
          config: WebViewConfig(
            cacheFirst: false,
            posture: site.sitePosture(
                globalUserScripts: const <UserScriptConfig>[],
                isolation: fakeSharedJar()),
            hooks: _hooks(),
            initialUrl: 'https://example.com/',
          ),
          onControllerCreated: (_) {},
        ),
      ));
      await created(tester);
      final attaches = [
        for (final c in sent)
          if (c.method == 'attachToView') c.arguments as Map,
      ];
      expect(attaches, isNotEmpty);
      for (final a in attaches) {
        expect(a, containsPair('contentBlock', false));
      }
      await tester.runAsync(() async {
        attach.complete(true);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
    });

    testWidgets('a load another path issues', (tester) async {
      late WebViewController controller;
      await tester.pumpWidget(
          _webView(onControllerCreated: (c) => controller = c));
      final native = await created(tester);
      native.calls.clear();
      await tester.runAsync(() async {
        final reload = controller.reload();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(native.calls, isNot(contains('reload')));
        attach.complete(true);
        await reload;
      });
      expect(native.calls, contains('reload'));
    });
  });

  // The import's URL has nothing behind it (IMPORT-005), so every load of it,
  // the held first load included, renders the stored document instead.
  test('a load of an import\'s URL renders the import, however it is issued',
      () async {
    final native = _NativeController();
    final controller = PlatformWebViewController(
      native,
      pauseHack: PauseTimersHackState(),
      settings: inapp.InAppWebViewSettings(),
      loadsAfter: Future<void>.value(),
      fileImport: const FileImportDocument(
          url: 'file:///Notes.html', html: '<p>notes</p>'),
    );
    await controller.loadUrl('file:///Notes.html#top');
    await controller.loadRequest(
        inapp.URLRequest(url: inapp.WebUri('file:///Notes.html')));
    await controller.loadUrl('https://example.com/');
    expect(native.calls, ['loadData', 'loadData', 'loadUrl']);
  });

  group('a cookie jar that fails (ISO-014, CONT-009)', () {
    testWidgets(
        'ISO-014: a cookie read that fails after a load leaves the mirror '
        'alone and the load finishes', (tester) async {
      final jar = MockCookieManager()..failing.add(JarCall.read);
      final mirrored = <List<Cookie>>[];
      await tester.pumpWidget(_webView(
        hooks: _hooks(isolation: () => fakeSharedJar(cookies: jar)),
        onCookiesChanged: mirrored.add,
      ));
      final (:params, :native) = await _attach(tester);
      await tester.runAsync(() async {
        params.onLoadStop!(native, inapp.WebUri('https://example.com/'));
        await Future<void>.delayed(const Duration(milliseconds: 50));
      });
      expect(mirrored, isEmpty,
          reason: 'a read that failed is not an empty jar to mirror');
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
      await _hooks(isolation: () => fakeSharedJar(cookies: jar))
          .removeBlockedCookies(
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
