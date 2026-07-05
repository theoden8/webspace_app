// Coverage for the Dart-side JS-bridge handlers and re-injection
// orchestration in UserScriptService — the paths that were previously
// untested because they need an InAppWebViewController and the outbound
// HTTP client.
//
// The controller is faked (extends Fake) to capture the registered handler
// callbacks and record evaluateJavascript sources. The network layer is
// swapped via the documented `outboundHttp` seam with a MockClient.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

/// Serves a configurable response for every outbound fetch.
class _FakeFactory implements OutboundHttpFactory {
  final http.Response Function(http.Request request) responder;
  final List<Uri> requested = [];
  _FakeFactory(this.responder);

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    return OutboundClientReady(MockClient((req) async {
      requested.add(req.url);
      return responder(req);
    }));
  }
}

/// Captures the registered handler callbacks and records injected sources.
class _FakeController extends Fake implements inapp.InAppWebViewController {
  final Map<String, inapp.JavaScriptHandlerCallback> handlers = {};
  final List<String> evaluated = [];

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required inapp.JavaScriptHandlerCallback callback,
  }) {
    handlers[handlerName] = callback;
  }

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    inapp.ContentWorld? contentWorld,
  }) async {
    evaluated.add(source);
    return null;
  }

  inapp.JavaScriptHandlerCallback handler(String prefix) =>
      handlers.entries.firstWhere((e) => e.key.startsWith(prefix)).value;

  bool evaluatedAny(String needle) => evaluated.any((s) => s.contains(needle));
}

UserScriptService _serviceWith(
  List<UserScriptConfig> scripts, {
  Future<bool> Function(String url)? confirm,
}) =>
    UserScriptService(scripts: scripts, onConfirmScriptFetch: confirm);

final _oneScript = [UserScriptConfig(name: 't', source: 'noop;')];

void main() {
  // Handler names are randomized per instance but keep stable prefixes.
  const scriptPrefix = '__ws_s_';
  const inlinePrefix = '__ws_i_';
  const fetchPrefix = '__ws_f_';

  group('__wsFetch resource handler', () {
    test('returns status/body/contentType for an allowed URL', () async {
      outboundHttp = _FakeFactory((_) =>
          http.Response('BODY', 200, headers: {'content-type': 'text/css'}));
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(fetchPrefix)(['https://example.com/x.css'])
          as Map;
      expect(res['status'], 200);
      expect(res['body'], 'BODY');
      expect(res['contentType'], 'text/css');
    });

    test('blocks dangerous schemes with 403 without fetching', () async {
      final factory = _FakeFactory((_) => http.Response('x', 200));
      outboundHttp = factory;
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final res =
          await ctrl.handler(fetchPrefix)(['data:text/html,x']) as Map;
      expect(res['status'], 403);
      expect(factory.requested, isEmpty);
    });

    test('rejects an oversize response with 413', () async {
      final big = 'a' * (5 * 1024 * 1024 + 1);
      outboundHttp = _FakeFactory((_) => http.Response(big, 200));
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final res =
          await ctrl.handler(fetchPrefix)(['https://example.com/big']) as Map;
      expect(res['status'], 413);
    });

    test('non-string argument returns a 400', () async {
      outboundHttp = _FakeFactory((_) => http.Response('x', 200));
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final res = await ctrl.handler(fetchPrefix)([42]) as Map;
      expect(res['status'], 400);
    });
  });

  group('script fetch handler', () {
    test('fetches a whitelisted URL and injects the body', () async {
      outboundHttp = _FakeFactory((_) => http.Response('CODE_A();', 200));
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(scriptPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);
      expect(ok, isTrue);
      expect(ctrl.evaluatedAny('CODE_A();'), isTrue);
    });

    test('blocks a non-whitelisted URL when there is no confirm handler',
        () async {
      final factory = _FakeFactory((_) => http.Response('CODE;', 200));
      outboundHttp = factory;
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final ok =
          await ctrl.handler(scriptPrefix)(['https://evil.example/x.js']);
      expect(ok, isFalse);
      expect(factory.requested, isEmpty);
      expect(ctrl.evaluatedAny('CODE;'), isFalse);
    });

    test('fetches a non-whitelisted URL after the user confirms', () async {
      outboundHttp = _FakeFactory((_) => http.Response('CONFIRMED();', 200));
      final ctrl = _FakeController();
      _serviceWith(_oneScript, confirm: (_) async => true).registerHandlers(ctrl);

      final ok =
          await ctrl.handler(scriptPrefix)(['https://ok.example/x.js']);
      expect(ok, isTrue);
      expect(ctrl.evaluatedAny('CONFIRMED();'), isTrue);
    });

    test('returns false and injects nothing on a non-200 response', () async {
      outboundHttp = _FakeFactory((_) => http.Response('nope', 404));
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);

      final ok = await ctrl
          .handler(scriptPrefix)(['https://cdn.jsdelivr.net/npm/x/x.js']);
      expect(ok, isFalse);
      expect(ctrl.evaluated, isEmpty);
    });
  });

  group('inline script handler', () {
    test('evaluates the bridged inline source', () async {
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);
      await ctrl.handler(inlinePrefix)(['window.__x = 1;']);
      expect(ctrl.evaluatedAny('window.__x = 1;'), isTrue);
    });

    test('ignores empty inline source', () async {
      final ctrl = _FakeController();
      _serviceWith(_oneScript).registerHandlers(ctrl);
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
      final ctrl = _FakeController();
      await _serviceWith(mixed()).reinjectOnLoadStart(ctrl);

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
      final ctrl = _FakeController();
      await _serviceWith(mixed()).reinjectOnLoadStop(ctrl);

      expect(ctrl.evaluatedAny('Node.prototype.appendChild'), isFalse,
          reason: 'load stop must not re-inject the shim');
      expect(ctrl.evaluatedAny('END();'), isTrue);
      expect(ctrl.evaluatedAny('START();'), isFalse);
      expect(ctrl.evaluatedAny('LIB();'), isFalse);
    });
  });
}
