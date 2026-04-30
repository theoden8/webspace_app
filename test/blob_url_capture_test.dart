import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/blob_url_capture.dart';

void main() {
  group('blobUrlCaptureScript', () {
    test('emits the reentrance guard so repeat frames do not re-wrap', () {
      // initialUserScripts re-fire on every frame load; without the
      // `if (window.__webspaceBlobs) return` guard the wrapper would
      // re-wrap and forget the previously-captured blobs each time.
      expect(blobUrlCaptureScript, contains('if (window.__webspaceBlobs) return'));
    });

    test('wraps both URL.createObjectURL and URL.revokeObjectURL', () {
      // If only createObjectURL is wrapped, the map grows without bound;
      // if only revokeObjectURL is wrapped, captures never happen.
      expect(blobUrlCaptureScript, contains('URL.createObjectURL = function'));
      expect(blobUrlCaptureScript, contains('URL.revokeObjectURL = function'));
      expect(blobUrlCaptureScript, contains('var origCreate = URL.createObjectURL'));
      expect(blobUrlCaptureScript, contains('var origRevoke = URL.revokeObjectURL'));
    });

    test('only tracks values that are instanceof Blob', () {
      // URL.createObjectURL also accepts MediaSource on some platforms;
      // capturing those would put a non-Blob into the map and crash the
      // download IIFE when it hands a MediaSource to FileReader.
      expect(blobUrlCaptureScript, contains('obj instanceof Blob'));
    });

    test('exposes the global the download IIFE looks up', () {
      // The IIFE in webview.dart reads window.__webspaceBlobs.get(url);
      // changing the export name here without updating the IIFE silently
      // disables the fix. The cross-check test below ties the two ends.
      expect(blobUrlCaptureScript, contains("'__webspaceBlobs'"));
      expect(blobUrlCaptureScript, contains('Object.defineProperty(window'));
      expect(blobUrlCaptureScript, contains('enumerable: false'));
    });

    test('caps the map at MAX = 64 entries with FIFO eviction', () {
      // A page that mints blob URLs but never revokes (some SPAs) would
      // otherwise grow the map without limit and pin every Blob in
      // memory. The bound makes the leak survivable.
      expect(blobUrlCaptureScript, contains('MAX = 64'));
      expect(blobUrlCaptureScript, contains('keys.shift()'));
      expect(blobUrlCaptureScript, contains('map.delete(oldest)'));
    });

    test('is wired into WebViewFactory at AT_DOCUMENT_START', () {
      // Regression guard for the user-script registration in webview.dart.
      // If the registration is dropped (or moved past DOCUMENT_END), the
      // shim never gets a chance to wrap createObjectURL before the page
      // calls it, and github.com downloads silently break again.
      final webviewSrc = File('lib/services/webview.dart').readAsStringSync();
      expect(webviewSrc, contains("groupName: 'blob_url_capture'"));
      // Find the registration block and make sure the injection time on it
      // is DOCUMENT_START.
      final blockStart = webviewSrc.indexOf("groupName: 'blob_url_capture'");
      expect(blockStart, greaterThan(0));
      final blockEnd = webviewSrc.indexOf('));', blockStart);
      expect(blockEnd, greaterThan(blockStart));
      final block = webviewSrc.substring(blockStart, blockEnd);
      expect(block, contains('AT_DOCUMENT_START'));
      expect(block, contains(r'$blobUrlCaptureScript'));
    });

    test('blob-download IIFE looks up the same global the shim exports', () {
      // The shim and the IIFE in webview.dart are an implicit contract:
      // both must agree on `window.__webspaceBlobs` as the export name.
      // A refactor that renames either side silently disables the
      // captured-blob fast path and falls back to fetch — which is what
      // we just fixed.
      final webviewSrc = File('lib/services/webview.dart').readAsStringSync();
      expect(webviewSrc, contains('window.__webspaceBlobs'));
      expect(webviewSrc, contains('window.__webspaceBlobs.get(blobUrl)'));
    });
  });
}
