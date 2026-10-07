import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/settings/user_script.dart';
import 'package:webspace/web_view_model.dart';

/// The native controller as the plugin hands it over: records what reaches
/// the platform and fails a call the way [failWith] says.
class _NativeController implements inapp.InAppWebViewController {
  final List<String> calls = [];
  Object? failWith;

  Future<Null> _call(String name) async {
    calls.add(name);
    if (failWith case final error?) throw error;
    return null;
  }

  @override
  Future<void> reload() => _call('reload');

  // A completed Future<Null> passes for every Future<T?> the factory awaits.
  // ignore: prefer_void_to_null
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      invocation.isMethod ? Future<Null>.value() : null;
}

Future<inapp.InAppWebView> _pump(
  WidgetTester tester, {
  String? initialHtml,
  VoidCallback? onReloadIssued,
}) async {
  AndroidInAppWebViewPlatform.registerWith();
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform_views,
    (call) async => call.method == 'create' ? 0 : null,
  );
  final site = WebViewModel(initUrl: 'https://example.com/');
  await tester.pumpWidget(MaterialApp(
    home: WebViewFactory.createWebView(
      config: WebViewConfig(
        posture:
            site.sitePosture(globalUserScripts: const <UserScriptConfig>[]),
        initialUrl: 'https://example.com/',
        initialHtml: initialHtml,
        onReloadIssued: onReloadIssued,
      ),
      onControllerCreated: (_) {},
    ),
  ));
  return tester.widget<inapp.InAppWebView>(find.byType(inapp.InAppWebView));
}

void main() {
  tearDown(ConnectivityService.reset);

  testWidgets('a failed live-swap reload is the reload\'s own failure',
      (tester) async {
    ConnectivityService.onlineOverride = Future.value(true);
    var reloads = 0;
    final view = await _pump(
      tester,
      initialHtml: '<p>cached</p>',
      onReloadIssued: () => reloads++,
    );
    final native = _NativeController()
      ..failWith = PlatformException(code: 'reload');
    final params = view.platform.params;
    await tester.runAsync(() async {
      params.onWebViewCreated!(native);
      params.onLoadStop!(native, inapp.WebUri('https://example.com/'));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    expect(native.calls, ['reload']);
    expect(reloads, 1);
  });
}
