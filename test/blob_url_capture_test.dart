import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:webspace/services/blob_url_capture.dart';
import 'package:webspace/services/page_js.dart';

void main() {
  group('PageJs.blobUrlCapture.script', () {
    test('emits the reentrance guard so repeat frames do not re-wrap', () {
      // initialUserScripts re-fire on every frame load; without the
      // `if (window.__webspaceBlobs) return` guard the wrapper would
      // re-wrap and forget the previously-captured blobs each time.
      expect(PageJs.blobUrlCapture.script, contains('if (window.__webspaceBlobs) return'));
    });

    test('wraps both URL.createObjectURL and URL.revokeObjectURL', () {
      // If only createObjectURL is wrapped, the map grows without bound;
      // if only revokeObjectURL is wrapped, captures never happen.
      expect(PageJs.blobUrlCapture.script, contains('URL.createObjectURL = _patchedCreate'));
      expect(PageJs.blobUrlCapture.script, contains('URL.revokeObjectURL = _patchedRevoke'));
      expect(PageJs.blobUrlCapture.script, contains('var origCreate = URL.createObjectURL'));
      expect(PageJs.blobUrlCapture.script, contains('var origRevoke = URL.revokeObjectURL'));
    });

    test('only tracks values that are instanceof Blob', () {
      // URL.createObjectURL also accepts MediaSource on some platforms;
      // capturing those would put a non-Blob into the map and crash the
      // download IIFE when it hands a MediaSource to FileReader.
      expect(PageJs.blobUrlCapture.script, contains('obj instanceof Blob'));
    });

    test('exposes the global the download IIFE looks up', () {
      // The IIFE in webview.dart reads window.__webspaceBlobs.get(url);
      // changing the export name here without updating the IIFE silently
      // disables the fix. The cross-check test below ties the two ends.
      expect(PageJs.blobUrlCapture.script, contains("'__webspaceBlobs'"));
      expect(PageJs.blobUrlCapture.script, contains('Object.defineProperty(window'));
      expect(PageJs.blobUrlCapture.script, contains('enumerable: false'));
    });

    test('caps the map at MAX = 64 entries with FIFO eviction', () {
      // A page that mints blob URLs but never revokes (some SPAs) would
      // otherwise grow the map without limit and pin every Blob in
      // memory. The bound makes the leak survivable.
      expect(PageJs.blobUrlCapture.script, contains('MAX = 64'));
      expect(PageJs.blobUrlCapture.script, contains('keys.shift()'));
      expect(PageJs.blobUrlCapture.script, contains('map.delete(oldest)'));
    });

    test('revokeObjectURL is a passthrough — map entry survives revoke', () {
      // github.com's "Download raw file" handler synchronously revokes
      // the blob URL right after firing the <a download> click. Our
      // click interceptor's callHandler is async, so by the time Dart
      // re-enters JS to evaluate the download IIFE the revoke has
      // already run. Deleting the map entry on revoke makes the
      // IIFE's fast-path lookup miss, the fallback fetch fires,
      // and CSP connect-src kills it. Holding the Blob reference
      // through revoke keeps FileReader access working.
      expect(PageJs.blobUrlCapture.script,
          isNot(contains('map.delete(url)')));
      // The wrap must still chain to the original revoke so chromium's
      // public URL registry is cleaned up — the contract change is only
      // about our cache, not about the page-visible URL.
      expect(PageJs.blobUrlCapture.script,
          contains('origRevoke.apply(URL, arguments)'));
    });

    test('is wired into WebViewFactory at AT_DOCUMENT_START', () {
      // Regression guard for the user-script registration in webview.dart.
      // If the registration is dropped (or moved past DOCUMENT_END), the
      // shim never gets a chance to wrap createObjectURL before the page
      // calls it, and github.com downloads silently break again.
      final webviewSrc = File('lib/services/page_scripts.dart').readAsStringSync();
      final blockStart = webviewSrc.indexOf(
          RegExp(r"pageShim\('blob_url_capture',\s*js: PageJs.blobUrlCapture.script"));
      expect(blockStart, greaterThan(0));
      final block =
          webviewSrc.substring(blockStart, webviewSrc.indexOf(');', blockStart));
      expect(block, isNot(contains('ShimTime.end')));
    });

    test('blob-download IIFE looks up the same global the shim exports', () {
      // The shim and the IIFE are an implicit contract: both must agree
      // on `window.__webspaceBlobs` as the export name. A refactor that
      // renames either side silently disables the captured-blob fast
      // path and falls back to fetch — which is what we just fixed.
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:https://example.test/x',
        taskId: 't1',
        suggestedFilename: 'f.bin',
      );
      expect(iife, contains('window.__webspaceBlobs'));
      expect(iife, contains('window.__webspaceBlobs.get(blobUrl)'));
      // The IIFE must call out to the shim's API with the same key the
      // shim uses internally, otherwise the fast path is dead code.
      expect(PageJs.blobUrlCapture.script, contains("'__webspaceBlobs'"));
    });
  });

  group('buildBlobDownloadIife', () {
    test('substitutes blobUrl, taskId, and suggestedFilename verbatim', () {
      // jsonEncode is the only escaping the builder does. A refactor
      // that switches to naive interpolation would break on URLs/names
      // containing quotes or backslashes — guard against that by
      // asserting the JSON-encoded form is present.
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:https://example.test/abc',
        taskId: 'task-9',
        suggestedFilename: 'doc with "quotes".pdf',
      );
      expect(iife, contains('"blob:https://example.test/abc"'));
      expect(iife, contains('"task-9"'));
      expect(iife, contains(r'"doc with \"quotes\".pdf"'));
    });

    test('null suggestedFilename becomes empty string, not "null"', () {
      // The Dart handler treats empty string as "no suggested filename"
      // and falls through to a mime-derived fallback. A literal "null"
      // would propagate to the save dialog as the filename.
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:https://example.test/y',
        taskId: 't2',
      );
      expect(iife, contains('""'));
      expect(iife, isNot(contains('"null"')));
    });

    test('emits both fast-path and fetch-fallback branches', () {
      // The whole point of the rewrite. If a future change accidentally
      // drops the fast path the file would still parse but the CSP
      // bypass would silently regress.
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:test', taskId: 't',
      );
      expect(iife, contains('window.__webspaceBlobs.get(blobUrl)'));
      expect(iife, contains('readBlob(captured)'));
      expect(iife, contains('fetch(blobUrl)'));
    });

    test('routes success through _webspaceBlobDownload with 4 args', () {
      // filename, base64, mimeType, taskId — the Dart handler signature.
      // Reordering or omitting one corrupts every blob download.
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:test', taskId: 't',
      );
      expect(iife, contains("'_webspaceBlobDownload'"));
      // Argument order is positional — assert by surrounding context.
      expect(iife, contains('suggestedFilename,'));
      expect(iife, contains('base64,'));
      expect(iife, contains("blob.type || '',"));
      expect(iife, contains('taskId'));
    });

    test('routes errors through _webspaceBlobDownloadError with 2 args', () {
      // Both the synchronous try/catch AND the fetch .catch must funnel
      // through the same handler so the Dart side sees a single error
      // shape. A divergent error-reporting shape gets dropped silently.
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:test', taskId: 't',
      );
      expect(iife, contains("'_webspaceBlobDownloadError'"));
      expect(iife, contains('reader.onerror'));
      expect(iife, contains('.catch(reportError)'));
      expect(iife, contains('reportError(e)'));
    });

    test('reports progress through _webspaceBlobProgress', () {
      final iife = buildBlobDownloadIife(
        blobUrl: 'blob:test', taskId: 't',
      );
      expect(iife, contains("'_webspaceBlobProgress'"));
      expect(iife, contains('reader.onprogress'));
      expect(iife, contains('e.lengthComputable'));
    });
  });

  group('PageJs.blobDownloadClickIntercept.script', () {
    test('emits the reentrance guard so repeat frames do not re-hook', () {
      // initialUserScripts re-fire on every frame load; without the
      // guard the click listener would be added repeatedly and the
      // anchor click() would re-wrap, breaking page-side toString
      // hardening.
      expect(PageJs.blobDownloadClickIntercept.script,
          contains('if (window.__webspaceBlobClickHooked) return'));
    });

    test('only intercepts <a> with download attr AND blob: href', () {
      // A plain blob: anchor (no download attr) is a navigation, not a
      // download — the page wants to display the blob inline and we
      // must not preventDefault. The shape of the predicate is locked
      // in here as a contract.
      expect(PageJs.blobDownloadClickIntercept.script,
          contains("el.tagName !== 'A'"));
      expect(PageJs.blobDownloadClickIntercept.script,
          contains("el.hasAttribute('download')"));
      expect(PageJs.blobDownloadClickIntercept.script,
          contains("href.indexOf('blob:') === 0"));
    });

    test('catches both in-DOM clicks and detached link.click()', () {
      // The two paths are independent: a document capturing listener
      // for clicks on attached anchors, plus an
      // HTMLAnchorElement.prototype.click wrapper for the
      // very common create-set-click-discard pattern where the
      // anchor is never appended to the DOM and the event never
      // bubbles to document. Dropping either leaves a major SaveAs
      // flow broken.
      expect(PageJs.blobDownloadClickIntercept.script,
          contains("document.addEventListener('click'"));
      expect(PageJs.blobDownloadClickIntercept.script,
          contains('HTMLAnchorElement.prototype.click'));
    });

    test('bridges through _webspaceBlobDownloadStart with two args', () {
      // (blobUrl, filename). The Dart handler in webview.dart reads
      // args[0] as the URL and args[1] as the suggested filename;
      // reordering them silently misroutes the call.
      expect(PageJs.blobDownloadClickIntercept.script,
          contains("'_webspaceBlobDownloadStart'"));
      expect(PageJs.blobDownloadClickIntercept.script,
          contains("'_webspaceBlobDownloadStart', href, name"));
    });

    test('walks parentNode chain so clicks on anchor children resolve', () {
      // Pages routinely wrap an icon or <span> inside <a download>.
      // The event target is the inner element, not the anchor; the
      // shim must walk up until it finds the download anchor (or
      // bottoms out at document).
      expect(PageJs.blobDownloadClickIntercept.script, contains('el.parentNode'));
    });

    test('preventDefault + stopPropagation so the browser does not navigate', () {
      // Without preventDefault Android attempts to load the blob: URL
      // as a navigation, which paints ERR_UNKNOWN_URL_SCHEME and
      // strands the user. stopPropagation keeps a page-side click
      // handler from also acting on the same event (e.g. analytics
      // beacons).
      expect(PageJs.blobDownloadClickIntercept.script, contains('e.preventDefault()'));
      expect(PageJs.blobDownloadClickIntercept.script, contains('e.stopPropagation()'));
    });

    test('is wired into WebViewFactory at AT_DOCUMENT_START on Android', () {
      // Regression guard: the user-script registration must (a) exist,
      // (b) be Android-gated, and (c) inject at DOCUMENT_START so the
      // shim is in place before any page script can mint a blob URL
      // and wire a click handler against it.
      final webviewSrc = File('lib/services/page_scripts.dart').readAsStringSync();
      final blockStart = webviewSrc.indexOf(RegExp(
          r"'blob_download_click_intercept',\s*js: PageJs.blobDownloadClickIntercept.script"));
      expect(blockStart, greaterThan(0));
      final block =
          webviewSrc.substring(blockStart, webviewSrc.indexOf(');', blockStart));
      expect(block, isNot(contains('ShimTime.end')));
      // Android gate: the registration sits inside a hostIsAndroid block
      // (the web-safe Platform.isAndroid) so iOS/macOS keep using
      // onDownloadStartRequest natively.
      final preamble = webviewSrc.substring(
          // Anchor the search far enough back that the Platform check
          // for the script registration falls inside the slice.
          (blockStart - 200).clamp(0, blockStart),
          blockStart);
      expect(preamble, contains('hostIsAndroid'));
    });

    test('Dart handler for _webspaceBlobDownloadStart is registered', () {
      // The JS shim is dead weight without a matching addJavaScriptHandler.
      final webviewSrc = File('lib/services/page_handlers.dart').readAsStringSync();
      expect(webviewSrc, contains("handlerName: '_webspaceBlobDownloadStart'"));
      // The handler must funnel into the same handleBlobDownload entry
      // point the iOS/macOS onDownloadStartRequest path uses — otherwise
      // the captured-Blob fast path and DownloadsService task lifecycle
      // drift between platforms.
      final handlerStart =
          webviewSrc.indexOf("handlerName: '_webspaceBlobDownloadStart'");
      expect(handlerStart, greaterThan(0));
      final next = webviewSrc.indexOf('addJavaScriptHandler', handlerStart);
      final handler = webviewSrc.substring(
          handlerStart, next < 0 ? webviewSrc.length : next);
      expect(handler, contains('WebViewDownloads.handleBlobDownload('));
    });
  });
}
