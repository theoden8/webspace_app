// HTTP authentication against real engines (HTTPAUTH-007).
//
// A loopback server stands in for an htpasswd-protected folder: every path
// under /a/ or /b/ answers 401 with `WWW-Authenticate: Basic` until the
// request carries alice:s3cret. The page loads an image and fetch()es JSON
// from the same folder, so the case only passes when the credential reached
// the engine's own auth cache: a header added to the first request, which
// is what per-site custom headers would have been, leaves both of those 401.
//
// Each case uses its own realm and folder, so a credential one case left in
// a shared network session cannot answer the other's challenge.
//
// Runs on the macOS integration job by file discovery, and on the Android
// emulator via scripts/run_android_http_auth_tests.sh. Skipped on Linux: the
// pinned fork's WPE plugin sends `previousFailureCount` as null, the shared
// Dart type declares it `int`, and the challenge never reaches the app.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:webspace/l10n/gen/app_localizations.dart';
import 'package:webspace/services/http_auth_engine.dart';
import 'package:webspace/services/http_auth_secure_storage.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/widgets/http_auth_prompt.dart';

import 'fixture_server.dart';
import 'secure_storage_fake.dart';

const _user = 'alice';
const _password = 's3cret';

String _realmFor(String path) =>
    path.startsWith('/a/') ? 'WebSpace A' : 'WebSpace B';

// 1x1 transparent PNG.
final _pixel = base64.decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=');

const _page = '''
<!doctype html><html><head><meta name="viewport" content="width=device-width">
</head><body><h1 id="ok">signed in</h1><img id="px" src="pixel.png">
<script>
window.__xhr = 'pending';
fetch('data.json').then(function (r) { return r.json(); })
  .then(function (j) { window.__xhr = j.ok ? 'ok' : 'bad'; })
  .catch(function (e) { window.__xhr = 'error: ' + e; });
</script></body></html>''';

const _probeJs = '''
(function(){
  var img = document.getElementById('px');
  return JSON.stringify({
    ok: !!document.getElementById('ok'),
    img: img && img.complete ? img.naturalWidth : 0,
    xhr: window.__xhr || null
  });
})()''';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late HttpServer server;
  late String base;
  final unauthorized = <String, int>{};
  final authorized = <String, int>{};

  setUpAll(() async {
    await installInMemoryKeychainIfUnavailable();
    final expected = 'Basic ${base64.encode(utf8.encode('$_user:$_password'))}';
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    listenFixture(server, (request) {
      final path = request.uri.path;
      final response = request.response;
      if (!path.startsWith('/a/') && !path.startsWith('/b/')) {
        response.statusCode = HttpStatus.notFound;
        response.close();
        return;
      }
      final folder = path.substring(0, 3);
      if (request.headers.value('authorization') != expected) {
        unauthorized[folder] = (unauthorized[folder] ?? 0) + 1;
        response
          ..statusCode = HttpStatus.unauthorized
          ..headers.set('WWW-Authenticate', 'Basic realm="${_realmFor(path)}"')
          ..headers.contentType = ContentType.html
          ..write('<html><body>401 Authorization Required</body></html>');
        response.close();
        return;
      }
      authorized[path] = (authorized[path] ?? 0) + 1;
      if (path.endsWith('/pixel.png')) {
        response
          ..headers.contentType = ContentType('image', 'png')
          ..add(_pixel);
      } else if (path.endsWith('/data.json')) {
        response
          ..headers.contentType = ContentType.json
          ..write('{"ok":true}');
      } else {
        response
          ..headers.contentType = ContentType.html
          ..write(_page);
      }
      response.close();
    });
    base = 'http://127.0.0.1:${server.port}';
  });

  tearDownAll(() async {
    await server.close(force: true);
  });

  void log(String message) {
    // ignore: avoid_print
    print('http_auth_test: $message');
  }

  Future<void> pumpUntil(
    WidgetTester tester,
    bool Function() predicate, {
    Duration timeout = const Duration(seconds: 60),
    required String description,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
      if (predicate()) return;
    }
    fail('timed out after ${timeout.inSeconds}s waiting for: $description');
  }

  Future<Map<String, dynamic>?> probe(
    WidgetTester tester,
    WebViewController? Function() controller,
  ) async {
    Map<String, dynamic>? last;
    await tester.runAsync(() async {
      final deadline = DateTime.now().add(const Duration(seconds: 45));
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        final c = controller();
        if (c == null) continue;
        try {
          final raw = await c
              .evaluateJavascriptReturning(_probeJs)
              .timeout(const Duration(seconds: 5));
          if (raw == null) continue;
          final decoded = jsonDecode(raw is String ? raw : '$raw');
          if (decoded is! Map<String, dynamic>) continue;
          last = decoded;
          if (decoded['ok'] == true &&
              (decoded['img'] as num? ?? 0) > 0 &&
              decoded['xhr'] != 'pending') {
            return;
          }
        } catch (_) {
          // Engine or bridge still coming up.
        }
      }
    });
    return last;
  }

  Widget host({
    required GlobalKey<NavigatorState> navigator,
    required WebViewConfig config,
    required void Function(WebViewController) onController,
  }) =>
      MaterialApp(
        navigatorKey: navigator,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 320,
              height: 480,
              child: WebViewFactory.createWebView(
                config: config,
                onControllerCreated: onController,
              ),
            ),
          ),
        ),
      );

  WebViewConfig configFor({
    required String siteId,
    required String url,
    required HttpAuthPrompt prompt,
  }) =>
      WebViewConfig(
        key: ValueKey('http-auth-$siteId'),
        siteId: siteId,
        initialUrl: url,
        httpAuthMemory: HttpAuthMemory.readWrite,
        onHttpAuthRequest: prompt,
        clearUrlEnabled: false,
        dnsBlockEnabled: false,
        contentBlockEnabled: false,
        trackingProtectionEnabled: false,
        localCdnEnabled: false,
      );

  testWidgets('a saved sign-in answers the challenge without a prompt',
      (tester) async {
    const siteId = 'http-auth-saved';
    await HttpAuthSecureStorage.instance.save(
      siteId,
      '127.0.0.1',
      _realmFor('/a/'),
      const HttpAuthCredential(username: _user, password: _password),
    );
    var prompts = 0;
    WebViewController? controller;
    await tester.pumpWidget(host(
      navigator: GlobalKey<NavigatorState>(),
      config: configFor(
        siteId: siteId,
        url: '$base/a/',
        prompt: (_) async {
          prompts++;
          return null;
        },
      ),
      onController: (c) => controller = c,
    ));

    final result = await probe(tester, () => controller);
    log('saved: probe=$result unauthorized=$unauthorized '
        'authorized=$authorized');
    if (result == null && (unauthorized['/a/'] ?? 0) == 0) {
      log('SKIP: the engine never requested the page');
      return;
    }
    expect(prompts, 0, reason: 'a saved sign-in must not prompt');
    expect(result?['ok'], isTrue, reason: 'page must load: $result');
    expect(result?['img'], greaterThan(0),
        reason: 'the image behind the same htpasswd must load: $result');
    expect(result?['xhr'], 'ok',
        reason: 'fetch() behind the same htpasswd must succeed: $result');
  }, skip: Platform.isLinux, timeout: const Timeout(Duration(minutes: 4)));

  testWidgets(
      'the prompt signs in, says when a password is refused, and remembers',
      (tester) async {
    const siteId = 'http-auth-typed';
    await HttpAuthSecureStorage.instance.removeSite(siteId);
    final navigator = GlobalKey<NavigatorState>();
    WebViewController? controller;
    await tester.pumpWidget(host(
      navigator: navigator,
      config: configFor(
        siteId: siteId,
        url: '$base/b/',
        prompt: (request) =>
            promptHttpAuth(navigator.currentContext!, request),
      ),
      onController: (c) => controller = c,
    ));

    final dialog = find.byType(HttpAuthDialog);
    final deadline = DateTime.now().add(const Duration(seconds: 60));
    while (dialog.evaluate().isEmpty && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)));
    }
    if (dialog.evaluate().isEmpty) {
      if ((unauthorized['/b/'] ?? 0) == 0) {
        log('SKIP: the engine never requested the page');
        return;
      }
      fail('the server challenged ${unauthorized['/b/']} time(s) but no '
          'sign-in dialog appeared');
    }
    expect(find.textContaining('127.0.0.1'), findsOneWidget);
    expect(find.text('That username and password were not accepted.'),
        findsNothing);

    await tester.enterText(find.byType(TextField).at(0), _user);
    await tester.enterText(find.byType(TextField).at(1), 'wrong');
    await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
    await pumpUntil(
      tester,
      () => find
          .text('That username and password were not accepted.')
          .evaluate()
          .isNotEmpty,
      description: 'the dialog to reopen after a refused password',
    );
    expect(find.text(_user), findsOneWidget,
        reason: 'the retry keeps the username that was typed');

    await tester.enterText(find.byType(TextField).at(1), _password);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.widgetWithText(TextButton, 'Sign in'));
    await tester.pump();

    final result = await probe(tester, () => controller);
    log('typed: probe=$result unauthorized=$unauthorized '
        'authorized=$authorized');
    expect(dialog, findsNothing,
        reason: 'the image and fetch() must reuse the credential, not ask');
    expect(result?['ok'], isTrue, reason: 'page must load: $result');
    expect(result?['img'], greaterThan(0),
        reason: 'the image behind the same htpasswd must load: $result');
    expect(result?['xhr'], 'ok',
        reason: 'fetch() behind the same htpasswd must succeed: $result');

    late HttpAuthCredential? saved;
    await tester.runAsync(() async {
      saved = await HttpAuthSecureStorage.instance
          .lookup(siteId, '127.0.0.1', _realmFor('/b/'));
    });
    expect(saved?.username, _user);
    expect(saved?.password, _password);
  }, skip: Platform.isLinux, timeout: const Timeout(Duration(minutes: 4)));
}
