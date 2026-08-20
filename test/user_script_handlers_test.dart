// Coverage for the Dart-side JS-bridge handlers and re-injection
// orchestration in UserScriptService — the paths that need an
// InAppWebViewController and the outbound HTTP client.
//
// Fakes live in test/helpers/user_script_bridge_fakes.dart, shared with
// user_script_bridge_authz_test.dart.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/user_script.dart';

import 'helpers/user_script_bridge_fakes.dart';

void main() {
  const scriptPrefix = '__ws_s_';
  const inlinePrefix = '__ws_i_';
  const fetchPrefix = '__ws_f_';

  group('__wsFetch resource handler', () {
    test('returns status/body/contentType for an allowed URL', () async {
      outboundHttp = FakeOutboundFactory((_) =>
          http.Response('BODY', 200, headers: {'content-type': 'text/css'}));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(fetchPrefix)(['https://example.com/x.css']);
      expect((res as Map)['status'], 200);
      expect(res['body'], 'BODY');
      expect(res['contentType'], 'text/css');
    });

    test('blocks dangerous schemes with 403 without fetching', () async {
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(fetchPrefix)(['data:text/html,x']);
      expect((res as Map)['status'], 403);
      expect(factory.requested, isEmpty);
    });

    test('rejects an oversize response with 413', () async {
      final big = 'a' * (5 * 1024 * 1024 + 1);
      outboundHttp = FakeOutboundFactory((_) => http.Response(big, 200));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(fetchPrefix)(['https://example.com/big']);
      expect((res as Map)['status'], 413);
    });

    test('non-string argument returns a 400', () async {
      outboundHttp = FakeOutboundFactory((_) => http.Response('x', 200));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(fetchPrefix)([42]);
      expect((res as Map)['status'], 400);
    });
  });

  group('script fetch handler', () {
    test('fetches a whitelisted URL and injects the body', () async {
      outboundHttp = FakeOutboundFactory((_) => http.Response('CODE_A();', 200));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(scriptPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);
      expect(ok, isTrue);
      expect(ctrl.evaluatedAny('CODE_A();'), isTrue);
    });

    test('blocks a non-whitelisted URL when there is no confirm handler',
        () async {
      final factory = FakeOutboundFactory((_) => http.Response('CODE;', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final ok =
          await ctrl.handler(scriptPrefix)(['https://evil.example/x.js']);
      expect(ok, isFalse);
      expect(factory.requested, isEmpty);
      expect(ctrl.evaluatedAny('CODE;'), isFalse);
    });

    test('fetches a non-whitelisted URL after the user confirms', () async {
      outboundHttp = FakeOutboundFactory((_) => http.Response('CONFIRMED();', 200));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript, confirm: (_) async => true).registerHandlers(ctrl);

      final ok =
          await ctrl.handler(scriptPrefix)(['https://ok.example/x.js']);
      expect(ok, isTrue);
      expect(ctrl.evaluatedAny('CONFIRMED();'), isTrue);
    });

    test('returns false and injects nothing on a non-200 response', () async {
      outboundHttp = FakeOutboundFactory((_) => http.Response('nope', 404));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(scriptPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);
      expect(ok, isFalse);
      expect(ctrl.evaluated, isEmpty);
    });
  });

  group('inline script handler', () {
    test('evaluates the bridged inline source', () async {
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);
      await ctrl.handler(inlinePrefix)(['window.__x = 1;']);
      expect(ctrl.evaluatedAny('window.__x = 1;'), isTrue);
    });

    test('ignores empty inline source', () async {
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);
      await ctrl.handler(inlinePrefix)(['']);
      expect(ctrl.evaluated, isEmpty);
    });
  });

  group('re-injection orchestration', () {
    List<UserScriptConfig> mixed() => [
          UserScriptConfig(
              id: 's1',
              name: 'start',
              source: 'START();',
              injectionTime: UserScriptInjectionTime.atDocumentStart),
          UserScriptConfig(
              id: 's2',
              name: 'end',
              source: 'END();',
              injectionTime: UserScriptInjectionTime.atDocumentEnd),
          UserScriptConfig(
              id: 's3',
              name: 'lib',
              source: 'INIT();',
              urlSource: 'LIB();',
              injectionTime: UserScriptInjectionTime.atDocumentStart),
          UserScriptConfig(
              id: 's4',
              name: 'off',
              source: 'OFF();',
              injectionTime: UserScriptInjectionTime.atDocumentStart,
              enabled: false),
        ];

    test('onLoadStart re-runs the shim and only atStart non-library scripts',
        () async {
      final ctrl = FakeUserScriptController();
      await serviceWith(mixed()).reinjectOnLoadStart(ctrl);

      expect(ctrl.evaluatedAny('Node.prototype.appendChild'), isTrue,
          reason: 'shim must be re-injected at load start');
      expect(ctrl.evaluatedAny('START();'), isTrue);
      expect(ctrl.evaluatedAny('window.__wsRan_s1'), isTrue);
      expect(ctrl.evaluatedAny('END();'), isFalse);
      expect(ctrl.evaluatedAny('LIB();'), isFalse,
          reason: 'urlSource libraries are handled by initialUserScripts');
      expect(ctrl.evaluatedAny('OFF();'), isFalse);
    });

    test('onLoadStop re-runs only atEnd non-library scripts, no shim',
        () async {
      final ctrl = FakeUserScriptController();
      await serviceWith(mixed()).reinjectOnLoadStop(ctrl);

      expect(ctrl.evaluatedAny('Node.prototype.appendChild'), isFalse,
          reason: 'load stop must not re-inject the shim');
      expect(ctrl.evaluatedAny('END();'), isTrue);
      expect(ctrl.evaluatedAny('START();'), isFalse);
      expect(ctrl.evaluatedAny('LIB();'), isFalse);
    });
  });
}
