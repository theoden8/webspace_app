import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/page_js.dart';

void main() {
  group('PageJs.targetBlankRewrite.script', () {
    test('guards against double-installation', () {
      expect(PageJs.targetBlankRewrite.script,
          contains('if (window.__webspaceTargetBlankHooked) return'));
      expect(PageJs.targetBlankRewrite.script,
          contains('window.__webspaceTargetBlankHooked = true'));
    });

    test('rewrites only _blank / _new targets', () {
      expect(PageJs.targetBlankRewrite.script, contains("t === '_blank'"));
      expect(PageJs.targetBlankRewrite.script, contains("t === '_new'"));
      expect(PageJs.targetBlankRewrite.script, contains("setAttribute('target', '_self')"));
    });

    test('only touches http(s) anchors', () {
      expect(PageJs.targetBlankRewrite.script, contains("href.indexOf('http://') === 0"));
      expect(PageJs.targetBlankRewrite.script, contains("href.indexOf('https://') === 0"));
    });

    test('listens in capture phase and walks up to the anchor', () {
      expect(PageJs.targetBlankRewrite.script,
          contains("document.addEventListener('click', listener, true)"));
      expect(PageJs.targetBlankRewrite.script, contains("el.tagName !== 'A'"));
      expect(PageJs.targetBlankRewrite.script, contains('el = el.parentNode'));
    });

    test('is wired into WebViewFactory at AT_DOCUMENT_START', () {
      // Regression guard for the user-script registration in webview.dart.
      // If the registration is dropped (or moved past DOCUMENT_END), the
      // rewrite never runs before the page wires its own click handlers and
      // target="_blank" cross-domain taps go silent again (issue #405).
      final webviewSrc = File('lib/services/page_scripts.dart').readAsStringSync();
      final blockStart = webviewSrc.indexOf(
          "pageShim('target_blank_rewrite', js: PageJs.targetBlankRewrite.script");
      expect(blockStart, greaterThan(0));
      final block =
          webviewSrc.substring(blockStart, webviewSrc.indexOf(');', blockStart));
      expect(block, isNot(contains('ShimTime.end')));
      // Outbound links live inside embedded frames too.
      expect(block, contains('ShimFrames.all'));
    });
  });
}
