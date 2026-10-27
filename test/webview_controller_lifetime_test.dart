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
import 'package:webspace/services/developer_mode_service.dart';
import 'package:webspace/services/dns_block_service.dart';
import 'package:webspace/services/experimental_features_service.dart';
import 'package:webspace/services/external_url_engine.dart';
import 'package:webspace/services/file_store.dart';
import 'package:webspace/services/file_import_document.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/popup_webview.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart' show ProxyManager;
import 'package:webspace/settings/app_prefs.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/services/web_intercept_native.dart';
import 'package:webspace/services/isolation.dart';
import 'package:webspace/services/navigation_decision_engine.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_hooks.dart';

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
  _NativeController({
    inapp.PlatformInAppWebViewController? platform,
    this.label = 'site',
    this.settingsLog,
  }) : platform = platform ?? FakePlatformController();

  /// Which view this is in [settingsLog].
  final String label;

  /// Where this view's settings writes go, for a test that reads them
  /// across views.
  final List<String>? settingsLog;

  @override
  Future<void> setSettings({
    required inapp.InAppWebViewSettings settings,
  }) async =>
      settingsLog?.add('$label blockNetworkLoads=${settings.blockNetworkLoads}');

  @override
  Future<void> stopLoading() async => settingsLog?.add('$label stopLoading');

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

  /// Whether a load is in flight, and the URL the view reports meanwhile.
  bool loading = false;
  inapp.WebUri? url;

  @override
  Future<bool> isLoading() async => loading;

  @override
  Future<inapp.WebUri?> getUrl() async => url;

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

/// A host that answers nothing, but for [externalScheme] and [showPopup]
/// when a test asks what reached them, its cookies kept apart by [isolation].
WebViewHostHooks _hooks({
  Future<void> Function(ExternalUrlInfo info,
          {required WebViewController? loadIn})?
      externalScheme,
  Isolation Function()? isolation,
  Future<void> Function(int windowId,
          {required String url, required PopupKind kind})?
      showPopup,
}) =>
    WebViewHostHooks(
      isolation: isolation ?? fakeSharedJar,
      globalUserScripts: () => const [],
      save: () async {},
      rebuild: () {},
      launchNested: (_, {required posture, homeTitle}) {},
      openInBrowser: (_) async => false,
      openSiteSettings: (_) {},
      showPopup: showPopup ?? (_, {required url, required kind}) async {},
      externalScheme: externalScheme ?? (_, {required loadIn}) async {},
      confirmScriptFetch: (_) async => false,
      untrustedCertificate: (_, {required port, required certificate}) async =>
          false,
      httpAuth: (_) async => null,
      media: FakePrompter(),
    );

/// [_hooks] for a site's own webview, on screen, keeping every link;
/// [firstPageLoaded] hears the redirect-home offer.
SiteHooks _siteHooks({
  Future<void> Function(WebViewModel source, {required String url})?
      firstPageLoaded,
}) =>
    SiteHooks(
      host: _hooks(),
      onScreen: (_) => true,
      routeOutbound:
          (_, {required url, required decision, required hadGesture}) => false,
      linkMenu: (_, {required url}) async {},
      firstPageLoaded: firstPageLoaded ?? (_, {required url}) async {},
    );

Widget _webView({
  WebViewHostHooks? hooks,
  Key? key,
  bool cacheFirst = false,
  VoidCallback? onReloadIssued,
  void Function(WebViewController)? onControllerCreated,
  void Function(List<Cookie>)? onCookiesChanged,
  void Function(String url)? onFirstPageLoaded,
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
          onFirstPageLoaded: onFirstPageLoaded,
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

  testWidgets('failed main-frame HTTP responses do not offer a domain', (tester) async {
    final offered = <String>[];
    await tester.pumpWidget(_webView(onFirstPageLoaded: offered.add));
    final (:params, :native) = await _attach(tester);
    final url = inapp.WebUri('https://example.com/');
    await tester.runAsync(() async {
      params.onReceivedHttpError!(native,
        inapp.WebResourceRequest(url: url, isForMainFrame: true),
        inapp.WebResourceResponse(statusCode: 503),
      );
      params.onLoadStop!(native, url);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(offered, isEmpty);
  });

  testWidgets('the live page after the engine cache is offered once', (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);
    final offered = <String>[];
    await tester.pumpWidget(_webView(cacheFirst: true,
        onFirstPageLoaded: offered.add));
    final (:params, :native) = await _attach(tester);
    final url = inapp.WebUri('https://example.com/');
    await tester.runAsync(() async {
      params.onLoadStop!(native, url);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(offered, isEmpty, reason: 'the cache-first page is not live');
    await tester.runAsync(() async {
      params.onLoadStop!(native, url);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      params.onLoadStop!(native, url);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(offered, ['https://example.com/']);
  });

  test('a popup recognizes the resolved domain without admitting another site', () {
    const home = 'https://theguardian.co.uk/';
    const canonical = 'https://www.theguardian.com/uk';
    final boundary = NavigationBoundary(homeUrl: home, initialUrl: home)
      ..onCommit(canonical);
    final config = WebViewConfig(
      posture: _site.sitePosture(globalUserScripts: const [], isolation: fakeSharedJar()),
      hooks: _hooks(),
      initialUrl: home,
      cacheFirst: false,
      navigationBoundary: boundary,
    );
    for (final (url, expected) in [
      (canonical, inapp.NavigationActionPolicy.ALLOW),
      ('https://other.example/', inapp.NavigationActionPolicy.CANCEL),
    ]) {
      expect(WebViewFactory.onSiteNavigationPolicy(config,
        navigationAction: inapp.NavigationAction(
          request: inapp.URLRequest(url: inapp.WebUri(url)),
          isForMainFrame: true,
        ),
        popup: null,
      ), expected);
    }
  });

  testWidgets('file imports cannot establish a new initial domain', (tester) async {
    const home = 'file:///import/site.html';
    final guardian = WebViewModel(initUrl: home);
    await tester.pumpWidget(MaterialApp(home: guardian.getWebView(
      _siteHooks(), cacheFirst: false, initialHtml: '<p>Imported page with scripts</p>',
    )));
    final (:params, :native) = await _attach(tester);
    await tester.runAsync(() async {
      final target = inapp.WebUri('https://other.example/');
      params.onPageCommitVisible!(native, target);
      params.onUpdateVisitedHistory!(native, target, false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(guardian.currentUrl, home);
  });

  testWidgets('initial Guardian redirect commits and keeps article URLs in the site',
      (tester) async {
    final guardian = WebViewModel(initUrl: 'https://theguardian.co.uk/');
    final offered = <String>[];
    await tester.pumpWidget(MaterialApp(home: guardian.getWebView(_siteHooks(
      firstPageLoaded: (_, {required url}) async => offered.add(url),
    ), cacheFirst: false)));
    final (:params, :native) = await _attach(tester);
    const canonical = 'https://www.theguardian.com/uk';
    final policy = await tester.runAsync(() async =>
        params.shouldOverrideUrlLoading!(native, inapp.NavigationAction(
          request: inapp.URLRequest(url: inapp.WebUri(canonical)),
          isForMainFrame: true,
          hasGesture: false,
          isRedirect: true,
        )));
    expect(policy, inapp.NavigationActionPolicy.ALLOW);
    await tester.runAsync(() async {
      params.onPageCommitVisible!(native, inapp.WebUri(canonical));
      params.onUpdateVisitedHistory!(native, inapp.WebUri(canonical), false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(guardian.currentUrl, canonical);
    await tester.runAsync(() async {
      params.onLoadStop!(native, inapp.WebUri(canonical));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(offered, [canonical]);
    const article = 'https://www.theguardian.com/world/article';
    await tester.runAsync(() async {
      params.onUpdateVisitedHistory!(native, inapp.WebUri(article), false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(guardian.currentUrl, article);
    await tester.runAsync(() async {
      params.onLoadStop!(native, inapp.WebUri(article));
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(offered, [canonical], reason: 'only the first settled page is offered');
    await tester.runAsync(() async {
      params.onUpdateVisitedHistory!(native, inapp.WebUri('https://other.example/'), false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
    });
    expect(guardian.currentUrl, article,
        reason: 'later automatic cross-domain changes are still refused');
  });

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

  // Google's sign-in button opens its page with window.open and waits for
  // the window to post the result back, so it needs a real popup (#686).
  group('sign-in popups (NESTED-014)', () {
    const signIn = 'https://accounts.google.com/o/oauth2/v2/auth?display=popup';

    // Android's rule, where the experiment offers them; a test of the rule
    // everywhere else calls [graduated].
    setUp(() => PopupKind.debugSignInExperimental = true);
    tearDown(() => PopupKind.debugSignInExperimental = null);

    void switchOn() {
      DeveloperModeService.instance.debugSet(on: true);
      ExperimentalFeaturesService.instance
          .debugSet(ExperimentalFeature.signInPopups, on: true);
      addTearDown(() {
        DeveloperModeService.instance.debugSet(on: false);
        ExperimentalFeaturesService.instance
            .debugSet(ExperimentalFeature.signInPopups, on: false);
      });
    }

    /// The popups the site webview asked the host for after a window
    /// request for [url], and whether it took the window.
    Future<({bool? took, List<PopupKind> shown})> requestWindow(
        WidgetTester tester, {required String? url}) async {
      final shown = <PopupKind>[];
      await tester.pumpWidget(_webView(
          hooks: _hooks(showPopup: (_, {required url, required kind}) async {
        shown.add(kind);
      })));
      final (:params, :native) = await _attach(tester);
      final took = await tester.runAsync(() async => params.onCreateWindow!(
            native,
            inapp.CreateWindowAction(
              windowId: 7,
              request: inapp.URLRequest(
                  url: url == null ? null : inapp.WebUri(url)),
              isForMainFrame: true,
            ),
          ));
      return (took: took, shown: shown);
    }

    testWidgets('NESTED-014: the engine opens a window on its own only with '
        'the switch off', (tester) async {
      await tester.pumpWidget(_webView());
      expect(
          tester
              .widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
              .platform.params.initialSettings
              ?.javaScriptCanOpenWindowsAutomatically,
          isTrue);
      switchOn();
      await tester.pumpWidget(_webView(key: UniqueKey()));
      expect(
          tester
              .widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
              .platform.params.initialSettings
              ?.javaScriptCanOpenWindowsAutomatically,
          isFalse,
          reason: 'with the switch on, only a window a tap opened reaches '
              'onCreateWindow');
    });

    testWidgets('NESTED-001: with the switch off, only a captcha opens a '
        'window (NESTED-014)', (tester) async {
      final declined = await requestWindow(tester, url: signIn);
      expect(declined.took, isFalse);
      expect(declined.shown, isEmpty);
      final challenge = await requestWindow(tester,
          url: 'https://challenges.cloudflare.com/cdn-cgi/challenge-platform/x');
      expect(challenge.took, isTrue);
      expect(challenge.shown, [PopupKind.verification]);
    });

    testWidgets('NESTED-014: a sign-in window opens as a sign-in popup',
        (tester) async {
      switchOn();
      final (:took, :shown) = await requestWindow(tester, url: signIn);
      expect(took, isTrue);
      expect(shown, [PopupKind.signIn]);
    });

    testWidgets('NESTED-014: a window with no URL opens as a sign-in popup',
        (tester) async {
      switchOn();
      final (:took, :shown) = await requestWindow(tester, url: null);
      expect(took, isTrue);
      expect(shown, [PopupKind.signIn]);
    });

    /// The rule everywhere but Android: no experiment stands between a site
    /// and its switches.
    void graduated() => PopupKind.debugSignInExperimental = false;

    bool? opensWindowsItself(WidgetTester tester) => tester
        .widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
        .platform.params.initialSettings
        ?.javaScriptCanOpenWindowsAutomatically;

    testWidgets('NESTED-014: where they graduated a sign-in window opens as a '
        'sign-in popup with developer mode off', (tester) async {
      graduated();
      final (:took, :shown) = await requestWindow(tester, url: signIn);
      expect(took, isTrue);
      expect(shown, [PopupKind.signIn]);
      expect(opensWindowsItself(tester), isFalse);
    });

    testWidgets('NESTED-014: a site that turns them off declines a sign-in '
        'window', (tester) async {
      graduated();
      _site.signInPopups = false;
      addTearDown(() => _site.signInPopups = null);
      final (:took, :shown) = await requestWindow(tester, url: signIn);
      expect(took, isFalse);
      expect(shown, isEmpty);
      expect(opensWindowsItself(tester), isTrue,
          reason: 'the site is back to NESTED-001, where a script may open a '
              'captcha window');
    });

    testWidgets("NESTED-014: a site that follows the app takes the app's "
        'switch', (tester) async {
      graduated();
      AppPref.signInPopups.debugValue = false;
      addTearDown(() => AppPref.signInPopups.debugValue = true);
      final declined = await requestWindow(tester, url: signIn);
      expect(declined.took, isFalse);
      expect(declined.shown, isEmpty);
      _site.signInPopups = true;
      addTearDown(() => _site.signInPopups = null);
      final opened = await requestWindow(tester, url: signIn);
      expect(opened.took, isTrue);
      expect(opened.shown, [PopupKind.signIn]);
    });

    testWidgets('NESTED-014: any other window is still declined',
        (tester) async {
      switchOn();
      final (:took, :shown) =
          await requestWindow(tester, url: 'https://ads.example/landing');
      expect(took, isFalse);
      expect(shown, isEmpty);
    });

    test('NESTED-014: a sign-in popup stays on its provider or the site', () {
      final config = WebViewConfig(
        posture: _site.sitePosture(
            globalUserScripts: const [], isolation: fakeSharedJar()),
        hooks: _hooks(),
        initialUrl: 'https://example.com/',
        cacheFirst: false,
      );
      for (final (kind, url, expected) in [
        (PopupKind.signIn, signIn, inapp.NavigationActionPolicy.ALLOW),
        (PopupKind.signIn, 'https://example.com/auth/done',
            inapp.NavigationActionPolicy.ALLOW),
        (PopupKind.signIn, 'https://ads.example/',
            inapp.NavigationActionPolicy.CANCEL),
        (PopupKind.verification, signIn, inapp.NavigationActionPolicy.CANCEL),
        (null, signIn, inapp.NavigationActionPolicy.CANCEL),
      ]) {
        expect(
          WebViewFactory.onSiteNavigationPolicy(config,
              navigationAction: inapp.NavigationAction(
                request: inapp.URLRequest(url: inapp.WebUri(url)),
                isForMainFrame: true,
              ),
              popup: kind),
          expected,
          reason: '$kind $url',
        );
      }
    });

    /// A sign-in popup's answer to a top-level navigation to [url], and how
    /// often it closed; [started] has it start a page first.
    Future<({inapp.NavigationActionPolicy? policy, int closed})> popupNavigates(
        WidgetTester tester, {required String url, required bool started}) async {
      // No blocker to wait for, so a page may start (CB-001).
      final site = WebViewModel(
        initUrl: 'https://example.com/',
        contentBlockEnabled: false,
        trackingProtectionEnabled: false,
      );
      var closed = 0;
      await tester.pumpWidget(MaterialApp(
        home: PopupWebView.createPopupWebView(
          windowId: 1,
          kind: PopupKind.signIn,
          config: WebViewConfig(
            cacheFirst: false,
            posture: site.sitePosture(
                globalUserScripts: const <UserScriptConfig>[],
                isolation: fakeSharedJar()),
            hooks: _hooks(),
            initialUrl: 'https://example.com/',
          ),
          onCloseWindow: () => closed++,
        ),
      ));
      final (:params, :native) = await _attach(tester);
      final policy = await tester.runAsync(() async {
        if (started) params.onLoadStart!(native, inapp.WebUri(signIn));
        return params.shouldOverrideUrlLoading!(
          native,
          inapp.NavigationAction(
            request: inapp.URLRequest(url: inapp.WebUri(url)),
            isForMainFrame: true,
          ),
        );
      });
      return (policy: policy, closed: closed);
    }

    testWidgets('NESTED-014: a popup whose first page is refused closes',
        (tester) async {
      final (:policy, :closed) = await popupNavigates(tester,
          url: 'https://ads.example/', started: false);
      expect(policy, inapp.NavigationActionPolicy.CANCEL);
      expect(closed, 1, reason: 'a popup with nothing to show stays blank');
    });

    testWidgets('NESTED-014: a popup that showed a page stays open on a '
        'refused navigation', (tester) async {
      final (:policy, :closed) = await popupNavigates(tester,
          url: 'https://ads.example/', started: true);
      expect(policy, inapp.NavigationActionPolicy.CANCEL);
      expect(closed, 0);
    });

    testWidgets('NESTED-014: a popup whose first page is its provider stays '
        'open', (tester) async {
      final (:policy, :closed) =
          await popupNavigates(tester, url: signIn, started: false);
      expect(policy, inapp.NavigationActionPolicy.ALLOW);
      expect(closed, 0);
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
        home: PopupWebView.createPopupWebView(
            windowId: 1, kind: PopupKind.verification, config: config),
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
      refuses: (_) => false,
      navigationHeaders: const {},
      fileImport: const FileImportDocument(
          url: 'file:///Notes.html', html: '<p>notes</p>'),
    );
    await controller.loadUrl('file:///Notes.html#top');
    await controller.loadRequest(
        inapp.URLRequest(url: inapp.WebUri('file:///Notes.html')));
    await controller.loadUrl('https://example.com/');
    expect(native.calls, ['loadData', 'loadData', 'loadUrl']);
  });

  group('NAV-018: a reload while a page loads', () {
    PlatformWebViewController over(
      _NativeController native, {
      bool Function(String url)? refuses,
    }) =>
        PlatformWebViewController(
          native,
          pauseHack: PauseTimersHackState(),
          settings: inapp.InAppWebViewSettings(),
          loadsAfter: Future<void>.value(),
          refuses: refuses ?? (_) => false,
          navigationHeaders: const {'Accept-Language': 'de, *;q=0.5'},
        );

    test('NAV-018: loads the page in flight again, with the site\'s headers',
        () async {
      final native = _NativeController()
        ..loading = true
        ..url = inapp.WebUri('https://example.com/slow');
      expect(await over(native).reload(), isTrue);
      expect(native.calls, ['loadUrl'],
          reason: 'WebKit\'s reload would reload the page before it');
      expect(native.requests.single.url.toString(), 'https://example.com/slow');
      expect(native.requests.single.headers,
          {'Accept-Language': 'de, *;q=0.5'});
    });

    test('NAV-018: a settled page reloads as before', () async {
      final native = _NativeController()
        ..url = inapp.WebUri('https://example.com/');
      expect(await over(native).reload(), isTrue);
      expect(native.calls, ['reload']);
    });

    test('NAV-018: a load in flight with no web address reloads', () async {
      final native = _NativeController()
        ..loading = true
        ..url = inapp.WebUri('about:blank');
      await over(native).reload();
      expect(native.calls, ['reload']);
    });

    test('NAV-018: a load the site may not issue stays refused (LEAK-010)',
        () async {
      final native = _NativeController()
        ..loading = true
        ..url = inapp.WebUri('https://example.com/slow');
      await over(native, refuses: (_) => true).reload();
      expect(native.calls, isEmpty);
    });
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

  /// A popup runs as its opener's site, on the proxy rule the opener holds,
  /// and nothing else lists it there. While its dialog is up, a shortcut
  /// launch, a memory-pressure unload or a wake can take the opener off the
  /// rule; the popup then loaded through whatever route came next. So it
  /// stops loading and closes when its opener is told to (PROXY-008).
  group('a popup goes with the webview that opened it (PROXY-008)', () {
    const captcha = 'https://challenges.cloudflare.com/turnstile/v0/api.js';

    // One rule for the process, as on Android: the hosts CI runs this on
    // bind each store's proxy, where nothing is quieted (PROXY-027).
    setUp(() => ProxyManager.pinBindingForTest(ProxyBinding.processWide));
    tearDown(() => ProxyManager.pinBindingForTest(null));

    /// The site's webview with its popup up, and how often the popup closed.
    Future<({WebViewController opener, List<String> log, int Function() closed})>
        openPopup(WidgetTester tester) async {
      final log = <String>[];
      final popupFor = ValueNotifier<int?>(null);
      final shown = Completer<void>();
      var closed = 0;
      late WebViewController opener;
      final config = WebViewConfig(
        posture: _site.sitePosture(
            globalUserScripts: const <UserScriptConfig>[],
            isolation: fakeSharedJar()),
        hooks: _hooks(showPopup: (windowId, {required url, required kind}) {
          popupFor.value = windowId;
          return shown.future;
        }),
        initialUrl: 'https://example.com/',
        cacheFirst: false,
      );
      await tester.pumpWidget(MaterialApp(
        home: Column(children: [
          Expanded(
            child: WebViewFactory.createWebView(
              config: config,
              onControllerCreated: (c) => opener = c,
            ),
          ),
          ValueListenableBuilder<int?>(
            valueListenable: popupFor,
            builder: (_, windowId, _) => windowId == null
                ? const SizedBox()
                : Expanded(
                    child: PopupWebView.createPopupWebView(
                      windowId: windowId,
                      kind: PopupKind.verification,
                      onCloseWindow: () {
                        closed++;
                        popupFor.value = null;
                        if (!shown.isCompleted) shown.complete();
                      },
                    ),
                  ),
          ),
        ]),
      ));
      final site = _NativeController(settingsLog: log);
      final siteView =
          tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
      await tester.runAsync(() async {
        siteView.platform.params.onWebViewCreated!(site);
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      // Started in the real zone, where the popup's close resolves it.
      await tester.runAsync(() async {
        unawaited(Future.value(siteView.platform.params.onCreateWindow!(
          site,
          inapp.CreateWindowAction(
            windowId: 7,
            request: inapp.URLRequest(url: inapp.WebUri(captcha)),
            isForMainFrame: true,
          ),
        )));
      });
      await tester.pump();
      final popupView = tester
          .widgetList<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
          .last;
      expect(popupView, isNot(same(siteView)), reason: 'the popup is up');
      await tester.runAsync(() async {
        popupView.platform.params.onWebViewCreated!(_NativeController(
            platform: FakePlatformController(), label: 'popup', settingsLog: log));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      addTearDown(() {
        if (!shown.isCompleted) shown.complete();
      });
      return (opener: opener, log: log, closed: () => closed);
    }

    testWidgets('the opener told to stop loading stops and closes its popup '
        'first', (tester) async {
      final (:opener, :log, :closed) = await openPopup(tester);
      await tester.runAsync(opener.quiet);
      await tester.pump();
      expect(log, [
        'popup blockNetworkLoads=true',
        'popup stopLoading',
        'site blockNetworkLoads=true',
        'site stopLoading',
      ]);
      expect(closed(), 1);
      expect(find.byType(inapp.InAppWebView), findsOneWidget);
    });

    testWidgets('a popup that closed on its own is not closed again',
        (tester) async {
      final (:opener, :log, :closed) = await openPopup(tester);
      await tester.runAsync(() async {
        final popup = tester
            .widgetList<inapp.InAppWebView>(find.byType(inapp.InAppWebView))
            .last;
        popup.platform.params.onCloseWindow!(_NativeController());
      });
      await tester.pump();
      expect(closed(), 1);
      await tester.runAsync(opener.quiet);
      expect(log, ['site blockNetworkLoads=true', 'site stopLoading']);
      expect(closed(), 1);
    });
  });
}
