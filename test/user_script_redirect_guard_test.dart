// Redirect handling on the page-reachable JS bridge.
//
// classifyScriptFetchUrl only ever sees the URL the page hands in. `http`
// follows redirects transparently, so before the guard below a public host
// answering `302 Location: http://169.254.169.254/…` returned the
// private-network body to page JS — the SSRF check in
// user_script_bridge_authz_test.dart passed and was bypassed one hop later.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_script_service.dart'
    show fetchUserScriptSource;

import 'helpers/user_script_bridge_fakes.dart';

/// Serves one redirect per URL in [chain], then [terminal] for anything else.
FakeOutboundFactory redirectingFactory(
  Map<String, String> chain, {
  http.Response Function(http.Request request)? terminal,
}) =>
    FakeOutboundFactory((req) {
      final next = chain[req.url.toString()];
      if (next != null) {
        return http.Response('', 302, headers: {'location': next});
      }
      return (terminal ?? (_) => http.Response('TERMINAL', 200))(req);
    });

void main() {
  tearDown(resetOutboundHttp);

  group('__wsFetch re-classifies every redirect target', () {
    test('a redirect onto a link-local metadata host is refused', () async {
      final factory = redirectingFactory({
        'https://evil.example/hop': 'http://169.254.169.254/latest/meta-data/',
      }, terminal: (_) => http.Response('IAM_CREDENTIALS', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res =
          await ctrl.handler(kFetchHandlerPrefix)(['https://evil.example/hop']);

      expect((res as Map)['status'], 403);
      expect(res['body'], isNull);
      expect(factory.requested.map((u) => u.host), ['evil.example'],
          reason: 'the metadata endpoint must never be contacted');
    });

    for (final target in const [
      'http://127.0.0.1:8080/admin',
      'http://10.0.0.1/',
      'http://192.168.1.1/',
      'http://[::1]/',
      'http://localhost/admin',
    ]) {
      test('a redirect onto $target is refused', () async {
        final factory = redirectingFactory({'https://evil.example/hop': target});
        outboundHttp = factory;
        final ctrl = FakeUserScriptController();
        serviceWith(oneScript).registerHandlers(ctrl);

        final res = await ctrl
            .handler(kFetchHandlerPrefix)(['https://evil.example/hop']);

        expect((res as Map)['status'], 403, reason: target);
        expect(factory.requested.length, 1, reason: target);
      });
    }

    test('a relative Location is resolved before it is classified', () async {
      final factory = redirectingFactory({'https://a.example/hop': '/next'});
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res =
          await ctrl.handler(kFetchHandlerPrefix)(['https://a.example/hop']);

      expect((res as Map)['status'], 200,
          reason: 'a same-host relative hop is still allowed');
      expect(factory.requested.map((u) => u.path), ['/hop', '/next']);
    });

    test('a redirect onto another public host is still followed', () async {
      final factory = redirectingFactory({
        'https://a.example/x': 'https://b.example/y',
      }, terminal: (_) => http.Response('PAYLOAD', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res =
          await ctrl.handler(kFetchHandlerPrefix)(['https://a.example/x']);

      expect((res as Map)['status'], 200);
      expect(res['body'], 'PAYLOAD');
      expect(factory.requested.map((u) => u.host), ['a.example', 'b.example']);
    });

    test('an endless redirect chain is cut off', () async {
      final factory = FakeOutboundFactory((_) => http.Response('', 302,
          headers: {'location': 'https://loop.example/next'}));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res =
          await ctrl.handler(kFetchHandlerPrefix)(['https://loop.example/a']);

      expect((res as Map)['status'], 403);
      expect(factory.requested.length, 6,
          reason: 'five hops plus the original request');
    });
  });

  group('the script handler re-runs its full gate on each hop', () {
    test('a whitelisted CDN cannot redirect onto a private host', () async {
      final factory = redirectingFactory({
        'https://cdn.jsdelivr.net/npm/x/x.js': 'http://10.1.2.3/payload.js',
      }, terminal: (_) => http.Response('PWNED();', 200));
      outboundHttp = factory;
      final asked = <String>[];
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript, confirm: (url) async {
        asked.add(url);
        return true;
      }).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(kScriptHandlerPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);

      expect(ok, isFalse);
      expect(asked, isEmpty, reason: 'a blocked host is never offered to the user');
      expect(ctrl.evaluatedAny('PWNED();'), isFalse);
    });

    test('a whitelisted CDN redirecting off-whitelist asks the user', () async {
      final factory = redirectingFactory({
        'https://cdn.jsdelivr.net/npm/x/x.js': 'https://elsewhere.example/x.js',
      }, terminal: (_) => http.Response('ELSEWHERE();', 200));
      outboundHttp = factory;
      final asked = <String>[];
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript, confirm: (url) async {
        asked.add(url);
        return false;
      }).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(kScriptHandlerPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);

      expect(ok, isFalse);
      expect(asked, ['https://elsewhere.example/x.js'],
          reason: 'confirmation is for the origin that actually serves the code');
      expect(ctrl.evaluatedAny('ELSEWHERE();'), isFalse);
    });

    test('the same hop is injected once the user approves it', () async {
      outboundHttp = redirectingFactory({
        'https://cdn.jsdelivr.net/npm/x/x.js': 'https://elsewhere.example/x.js',
      }, terminal: (_) => http.Response('ELSEWHERE();', 200));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript, confirm: (_) async => true).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(kScriptHandlerPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);

      expect(ok, isTrue);
      expect(ctrl.evaluatedAny('ELSEWHERE();'), isTrue);
    });
  });

  group('editor URL-source download', () {
    test('refuses a redirect onto a private host', () async {
      final factory = redirectingFactory({
        'https://cdn.jsdelivr.net/npm/x/x.js': 'http://169.254.169.254/',
      }, terminal: (_) => http.Response('IAM_CREDENTIALS', 200));
      outboundHttp = factory;

      final result =
          await fetchUserScriptSource('https://cdn.jsdelivr.net/npm/x/x.js');

      expect(result.source, isNull);
      expect(factory.requested.length, 1);
    });
  });
}
