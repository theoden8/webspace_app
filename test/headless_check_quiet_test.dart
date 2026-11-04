import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/headless_site_check.dart';
import 'package:webspace/services/proxy_binding_engine.dart';
import 'package:webspace/services/webview_proxy.dart' show ProxyManager;

/// What the check's webview was asked, in order.
final List<String> _asked = [];

class _Controller implements inapp.InAppWebViewController {
  @override
  Future<void> setSettings({
    required inapp.InAppWebViewSettings settings,
  }) async => _asked.add(
    'setSettings blockNetworkLoads=${settings.blockNetworkLoads} '
    'javaScriptEnabled=${settings.javaScriptEnabled}',
  );

  @override
  Future<void> stopLoading() async => _asked.add('stopLoading');

  @override
  dynamic getViewId() => 'check-1';

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Headless implements inapp.HeadlessInAppWebView {
  @override
  Future<void> dispose() async => _asked.add('dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A wake's headless check runs as its site on the process-wide proxy rule,
/// and the plugin destroys its native webview only after it has loaded
/// `about:blank`: one that went on loading would send what it fetched through
/// whatever proxy the rule names once the check has left it. So the check
/// loads nothing more before it is disposed, and its dispose returns only
/// once the plugin reports the native view destroyed, so the rule's vacate
/// lets the next claim run only then (`ProcessRoute.vacate`, PROXY-008,
/// NOTIF-016).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const manager = MethodChannel('com.pichillilorenzo/flutter_inappwebview_manager');
  late Completer<void> destroyed;
  setUp(() {
    _asked.clear();
    destroyed = Completer<void>();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(manager, (call) async {
      if (call.method != 'whenWebViewDestroyed') return null;
      _asked.add('whenWebViewDestroyed ${(call.arguments as Map)['id']}');
      await destroyed.future;
      return true;
    });
    // One rule for the process, as on Android: the hosts CI runs this on
    // bind each store's proxy, where nothing is quieted (PROXY-027).
    ProxyManager.pinBindingForTest(ProxyBinding.processWide);
  });
  tearDown(() {
    ProxyManager.pinBindingForTest(null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(manager, null);
  });

  test(
    'a check is blocked and stopped before its webview goes (PROXY-008)',
    () async {
      final check = HeadlessSiteCheck.over(
        _Headless(),
        controller: _Controller(),
        settings: inapp.InAppWebViewSettings(javaScriptEnabled: false),
      );
      var ended = false;
      final ending = check.dispose().then((_) => ended = true);
      await pumpEventQueue();
      expect(_asked, [
        // The settings it runs with: a setSettings resets what it leaves out
        // (BUG-022).
        'setSettings blockNetworkLoads=true javaScriptEnabled=false',
        // A block reaches only requests not yet intercepted (BUG-037).
        'stopLoading',
        'dispose',
        // Android destroys the view only after it has loaded about:blank.
        'whenWebViewDestroyed check-1',
      ]);
      expect(ended, isFalse,
          reason: 'the check holds the rule until its native view is destroyed');
      destroyed.complete();
      await ending;
      await check.dispose();
      expect(_asked, hasLength(4), reason: 'a check ends once');
    },
  );
}
