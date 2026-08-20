// Shared fakes for the UserScriptService JS-bridge handlers.
//
// The controller is faked via noSuchMethod (intercepting the two methods
// the service actually calls, by Symbol) rather than typed overrides, so
// the tests do not depend on the fork's exact method signatures. The
// network layer is swapped through the documented `outboundHttp` seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:webspace/services/outbound_http.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/proxy.dart';
import 'package:webspace/settings/user_script.dart';

const String kScriptHandlerPrefix = '__ws_s_';
const String kInlineHandlerPrefix = '__ws_i_';
const String kFetchHandlerPrefix = '__ws_f_';

/// Serves a configurable response for every outbound fetch.
class FakeOutboundFactory implements OutboundHttpFactory {
  final http.Response Function(http.Request request) responder;
  final List<Uri> requested = [];
  FakeOutboundFactory(this.responder);

  @override
  OutboundClient clientFor(UserProxySettings settings) {
    return OutboundClientReady(MockClient((req) async {
      requested.add(req.url);
      return responder(req);
    }));
  }
}

/// Captures the registered handler callbacks and records injected sources.
/// Signatures mirror the fork's InAppWebViewController: the handler callback
/// is a bare `Function`, and evaluateJavascript takes an optional
/// `ContentWorld`.
class FakeUserScriptController extends Fake
    implements inapp.InAppWebViewController {
  final Map<String, Function> handlers = {};
  final List<String> evaluated = [];

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
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

  Function handler(String prefix) =>
      handlers.entries.firstWhere((e) => e.key.startsWith(prefix)).value;

  String handlerName(String prefix) =>
      handlers.keys.firstWhere((k) => k.startsWith(prefix));

  bool evaluatedAny(String needle) => evaluated.any((s) => s.contains(needle));
}

UserScriptService serviceWith(
  List<UserScriptConfig> scripts, {
  Future<bool> Function(String url)? confirm,
}) =>
    UserScriptService(scripts: scripts, onConfirmScriptFetch: confirm);

List<UserScriptConfig> get oneScript =>
    [UserScriptConfig(name: 't', source: 'noop;')];
