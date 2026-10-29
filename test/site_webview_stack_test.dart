import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/connectivity_service.dart';
import 'package:webspace/services/webview_host_hooks.dart';
import 'package:webspace/web_view_model.dart';
import 'package:webspace/web_view_model_hooks.dart';
import 'package:webspace/widgets/site_webview_stack.dart';
import 'package:webspace/widgets/stats_banner.dart';

import 'helpers/capture_fakes.dart';
import 'helpers/isolations.dart';

/// A host that answers nothing: the stack never reaches a prompt here.
SiteHooks _hooks() => SiteHooks(
      host: WebViewHostHooks(
        isolation: fakeSharedJar,
        globalUserScripts: () => const [],
        save: () async {},
        rebuild: () {},
        launchNested: (_, {required posture, homeTitle}) {},
        openInBrowser: (_) async => false,
        openSiteSettings: (_) {},
        showPopup: (_, {required url, required kind}) async {},
        externalScheme: (_, {required loadIn}) async {},
        confirmScriptFetch: (_) async => false,
        untrustedCertificate: (_, {required port, required certificate}) async =>
            false,
        httpAuth: (_) async => null,
        media: FakePrompter(),
      ),
      onScreen: (_) => true,
      routeOutbound:
          (_, {required url, required decision, required hadGesture}) => false,
      linkMenu: (_, {required url}) async {},
      firstPageLoaded: (_, {required url}) async {},
    );

void main() {
  setUp(() {
    AndroidInAppWebViewPlatform.registerWith();
    TestWidgetsFlutterBinding.ensureInitialized()
        .defaultBinaryMessenger
        .setMockMethodCallHandler(
          SystemChannels.platform_views,
          (call) async => call.method == 'create' ? 0 : null,
        );
  });
  tearDown(ConnectivityService.reset);

  Widget stack(List<WebViewModel> models,
          {required SiteHooks hooks, bool showStatsBanner = false}) =>
      MaterialApp(
        home: SiteWebViewStack(
          models: models,
          loaded: {for (final (i, _) in models.indexed) i},
          current: models.length - 1,
          hooks: hooks,
          showStatsBanner: showStatsBanner,
        ),
      );

  // The slots not on screen are offstage, which a finder skips by default.
  State webViewStateOf(WidgetTester tester, {required WebViewModel site}) =>
      tester.state(find.descendant(
        of: find.byWidget(site.webview!, skipOffstage: false),
        matching: find.byType(inapp.InAppWebView, skipOffstage: false),
        skipOffstage: false,
      ));

  // Matched by position, the slot a deleted site leaves would hand the next
  // site the deleted one's element, and the next site's own webview, page
  // and all, would be torn down and built again.
  testWidgets('a site keeps its own webview when a site before it goes (ISO-009)',
      (tester) async {
    final hooks = _hooks();
    final a = WebViewModel(initUrl: 'https://a.example/');
    final b = WebViewModel(initUrl: 'https://b.example/');
    await tester.pumpWidget(stack([a, b], hooks: hooks));
    final before = webViewStateOf(tester, site: b);
    expect(webViewStateOf(tester, site: a), isNot(same(before)));

    await tester.pumpWidget(stack([b], hooks: hooks));
    expect(webViewStateOf(tester, site: b), same(before));
  });

  testWidgets('a reorder moves each site with its webview (ISO-009)',
      (tester) async {
    final hooks = _hooks();
    final a = WebViewModel(initUrl: 'https://a.example/');
    final b = WebViewModel(initUrl: 'https://b.example/');
    await tester.pumpWidget(stack([a, b], hooks: hooks));
    final ofA = webViewStateOf(tester, site: a);
    final ofB = webViewStateOf(tester, site: b);

    await tester.pumpWidget(stack([b, a], hooks: hooks));
    expect(webViewStateOf(tester, site: a), same(ofA));
    expect(webViewStateOf(tester, site: b), same(ofB));
  });

  testWidgets('the banner setting decides whether a site shows one (DNS-013)',
      (tester) async {
    final hooks = _hooks();
    final a = WebViewModel(initUrl: 'https://a.example/');
    await tester.pumpWidget(stack([a], hooks: hooks, showStatsBanner: true));
    expect(find.byType(StatsBanner), findsOneWidget);

    await tester.pumpWidget(stack([a], hooks: hooks));
    expect(find.byType(StatsBanner), findsNothing);
  });
}
