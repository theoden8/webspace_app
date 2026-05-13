import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/webview.dart';
import 'package:webspace/web_view_model.dart';

class _StubController extends Fake implements WebViewController {}

void main() {
  group('WebViewModel.handleRendererGone', () {
    test('clears cached webview + controller and triggers a rebuild', () {
      var rebuilds = 0;
      final model = WebViewModel(
        initUrl: 'https://example.com',
        stateSetterF: () => rebuilds++,
      );
      model.webview = const SizedBox.shrink();
      model.controller = _StubController();

      model.handleRendererGone(didCrash: true);

      expect(model.webview, isNull,
          reason: 'Cached widget must be cleared so the next getWebView call '
              'constructs a fresh InAppWebView.');
      expect(model.controller, isNull,
          reason: 'The dead controller is unusable — keep it and the next '
              'pause/resume/setSettings call hits a torn-down platform view.');
      expect(rebuilds, 1,
          reason: 'Host must rebuild so the IndexedStack child reconstructs.');
    });

    test('handles a null stateSetterF without throwing', () {
      final model = WebViewModel(initUrl: 'https://example.com');
      model.webview = const SizedBox.shrink();
      model.controller = _StubController();

      expect(() => model.handleRendererGone(didCrash: false), returnsNormally);
      expect(model.webview, isNull);
      expect(model.controller, isNull);
    });

    test('didCrash=false (OS-killed renderer) still recreates', () {
      // Per Android docs: when didCrash is false the renderer was killed by
      // the system to reclaim memory. The recovery is the same as a hard
      // crash — the WebView object is unusable either way.
      var rebuilds = 0;
      final model = WebViewModel(
        initUrl: 'https://example.com',
        stateSetterF: () => rebuilds++,
      );
      model.webview = const SizedBox.shrink();
      model.controller = _StubController();

      model.handleRendererGone(didCrash: false);

      expect(model.webview, isNull);
      expect(model.controller, isNull);
      expect(rebuilds, 1);
    });
  });
}
