// The Dart half of WebKit's sub-resource interceptor: `blockCheck` judges a
// URL against the asking frame's origin and reads nothing else that varies by
// request, which is what lets lib/js/block_js_interceptor.js keep an answer
// per URL for its document (CB-020). The script's half is in
// test/js/block_interceptor_shim.test.js.
@TestOn('linux || mac-os')
library;

import 'package:flutter_inappwebview/flutter_inappwebview.dart' as inapp;
import 'package:flutter_inappwebview_android/flutter_inappwebview_android.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webspace/services/adblock_engine.dart';
import 'package:webspace/services/content_blocker_service.dart';
import 'package:webspace/services/page_handlers.dart';
import 'package:webspace/services/user_script_service.dart';
import 'package:webspace/services/webview_config.dart';
import 'package:webspace/web_view_model.dart';

import 'helpers/silent_hooks.dart';
import 'helpers/user_script_bridge_fakes.dart';

const _rules = '||tracker.example^\$domain=news.example\n';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final engine = AdblockEngine.load(_rules);
  final skip = engine == null ? 'needs libwebspace_adblock' : false;
  engine?.dispose();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AndroidInAppWebViewPlatform.registerWith();
    ContentBlockerService.instance.setRustEngineForTest(AdblockEngine.load(_rules));
  });
  tearDown(() => ContentBlockerService.instance.setRustEngineForTest(null));

  test('blockCheck judges a URL against the frame that asks', () {
    const page = 'https://news.example/article';
    final controller = FakeUserScriptController();
    PageHandlers.registerPageHandlers(
      controller,
      config: WebViewConfig(
        posture: WebViewModel(initUrl: page).sitePosture(globalUserScripts: const []),
        hooks: silentHooks(),
        initialUrl: page,
      ),
      userScriptService: UserScriptService(scripts: const []),
    );
    final blockCheck =
        controller.handlers['blockCheck']! as Object? Function(inapp.JavaScriptHandlerFunctionData);
    Object? ask(String origin, {required bool top}) => blockCheck(inapp.JavaScriptHandlerFunctionData(
          args: ['https://tracker.example/t.js'],
          isMainFrame: top,
          origin: inapp.WebUri(origin),
          requestUrl: inapp.WebUri('$origin/frame'),
        ));

    expect(ask('https://news.example', top: true), isTrue);
    expect(ask('https://blog.example', top: false), isFalse,
        reason: 'a frame of another site on the page is judged as that site');
    expect(ask('https://news.example', top: false), isTrue);
    expect(ask('null', top: false), isFalse, reason: 'an opaque origin names no site');
    expect(ask('https://news.example', top: true), isTrue,
        reason: 'the same question from the same document has the same answer');
  }, skip: skip);
}
