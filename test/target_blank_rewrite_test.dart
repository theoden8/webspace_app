import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/target_blank_rewrite.dart';

void main() {
  group('targetBlankRewriteScript', () {
    test('guards against double-installation', () {
      expect(targetBlankRewriteScript,
          contains('if (window.__webspaceTargetBlankHooked) return'));
      expect(targetBlankRewriteScript,
          contains('window.__webspaceTargetBlankHooked = true'));
    });

    test('rewrites only _blank / _new targets', () {
      expect(targetBlankRewriteScript, contains("t === '_blank'"));
      expect(targetBlankRewriteScript, contains("t === '_new'"));
      expect(targetBlankRewriteScript, contains("setAttribute('target', '_self')"));
    });

    test('only touches http(s) anchors', () {
      expect(targetBlankRewriteScript, contains("href.indexOf('http://') === 0"));
      expect(targetBlankRewriteScript, contains("href.indexOf('https://') === 0"));
    });

    test('listens in capture phase and walks up to the anchor', () {
      expect(targetBlankRewriteScript,
          contains("document.addEventListener('click', listener, true)"));
      expect(targetBlankRewriteScript, contains("el.tagName !== 'A'"));
      expect(targetBlankRewriteScript, contains('el = el.parentNode'));
    });

    test('is wired into WebViewFactory at AT_DOCUMENT_START', () {
      // Regression guard for the user-script registration in webview.dart.
      // If the registration is dropped (or moved past DOCUMENT_END), the
      // rewrite never runs before the page wires its own click handlers and
      // target="_blank" cross-domain taps go silent again (issue #405).
      final webviewSrc = File('lib/services/webview.dart').readAsStringSync();
      expect(webviewSrc, contains("groupName: 'target_blank_rewrite'"));
      final blockStart = webviewSrc.indexOf("groupName: 'target_blank_rewrite'");
      expect(blockStart, greaterThan(0));
      final blockEnd = webviewSrc.indexOf('));', blockStart);
      expect(blockEnd, greaterThan(blockStart));
      final block = webviewSrc.substring(blockStart, blockEnd);
      expect(block, contains('AT_DOCUMENT_START'));
      expect(block, contains(r'$targetBlankRewriteScript'));
      // Must reach iframes too — outbound links live inside embedded frames.
      expect(block, contains('forMainFrameOnly: false'));
    });
  });
}
