// Shared fakes for the UserScriptService JS-bridge handlers.
//
// The controller is faked via noSuchMethod (intercepting the two methods
// the service actually calls, by Symbol) rather than typed overrides, so
// the tests do not depend on the fork's exact method signatures. The
// network layer is FakeOutbound (fake_outbound.dart) on the `outboundHttp` seam.

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;

import 'package:webspace/services/dns_level_mask_engine.dart';
import 'package:webspace/services/host_resolution.dart';
import 'package:webspace/services/page_phase.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/settings/user_script.dart';

import 'fake_platform_controller.dart';

const String kScriptHandlerPrefix = '__ws_s_';
const String kInlineHandlerPrefix = '__ws_i_';
const String kFetchHandlerPrefix = '__ws_f_';

/// Captures the registered handler callbacks and records injected sources.
/// Signatures mirror the fork's InAppWebViewController: the handler callback
/// is a bare `Function`, and evaluateJavascript takes an optional
/// `ContentWorld`.
class FakeUserScriptController extends Fake
    implements inapp.InAppWebViewController {
  FakeUserScriptController() {
    phases.on(PageEvent.viewCreated, view: platform);
  }

  final Map<String, Function> handlers = {};
  final List<String> evaluated = [];

  @override
  final inapp.PlatformInAppWebViewController platform =
      FakePlatformController();

  /// The view's documents, as its callbacks would report them.
  final PagePhases phases = PagePhases(
    blocking: (
      clearUrls: false,
      dns: false,
      dnsLevel: null,
      contentBlock: false,
      localCdn: false,
      httpsUpgrade: false,
      contributesStats: false,
      blockedCookies: const {},
    ),
    dnsLevel: () => kDnsLevelOff,
  );

  /// The document the view shows now, as a handler takes it.
  PageScope page() => phases.page(this);

  /// The main frame loads another page: the document shown until now is
  /// gone.
  void navigate() => phases.on(PageEvent.loadStarted, view: platform);

  @override
  void addJavaScriptHandler({
    required String handlerName,
    required Function callback,
  }) {
    handlers[handlerName] = callback;
  }

  /// Called as each script lands, for a test that moves the page between
  /// two of them.
  void Function(String source)? onEvaluate;

  @override
  Future<dynamic> evaluateJavascript({
    required String source,
    inapp.ContentWorld? contentWorld,
  }) async {
    evaluated.add(source);
    onEvaluate?.call(source);
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
}) => UserScriptService(scripts: scripts, onConfirmScriptFetch: confirm);

/// A script that asked for the privileged bridge. The authorization probes
/// are about what the bridge admits once a user has granted it; whether it is
/// installed at all is [plainScript]'s question.
List<UserScriptConfig> get oneScript => [
  UserScriptConfig(name: 't', source: 'noop;', bypassSitePolicy: true),
];

/// An ordinary user script: runs its code, asks for no bridge.
List<UserScriptConfig> get plainScript => [
  UserScriptConfig(name: 't', source: 'noop;'),
];

/// Answers the resolving half of the SSRF guard without touching DNS.
///
/// The default answer is a routable address, so a test that says nothing
/// about resolution keeps testing what it was written to test. Name a host in
/// [table] to point it somewhere — `['127.0.0.1']` for the rebinding case, or
/// `[]` for a name that does not resolve.
///
/// Install in `setUp` and call [resetHostLookup] in `tearDown`: left
/// unstubbed, every one of these tests would depend on the sandbox resolving
/// `*.example`, which it does not.
void stubHostLookup([Map<String, List<String>> table = const {}]) {
  hostLookup = (host) async => table[host] ?? const ['93.184.216.34'];
}
