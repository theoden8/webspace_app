// Offline-snapshot integrity gate (INTEG-014). A main-frame load that
// failed for a network reason still commits the engine's own error page
// and still fires onLoadStop, so the HtmlCache save in that handler will
// happily serialize "connection refused" over the site's last-good
// snapshot — the exact bytes the offline cold-start path then renders.
//
// This is structural because neither desktop integration target can
// positively verify the guard: Linux WPE never delivers the failure to
// Dart (WEBKIT_NETWORK_ERROR_FAILED has no WebResourceErrorType mapping),
// and WKWebView never fires onLoadStop for a failed provisional
// navigation. Android commits the error page and is where the guard
// earns its keep, and no CI job runs the offline suite there.
// Behavioural coverage: integration_test/offline_connection_test.dart.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const src = fs.readFileSync(
  path.join(repoRoot, 'lib/services/webview.dart'),
  'utf8',
);

test('a failed main-frame navigation is recorded', () => {
  assert.match(
    src,
    /failedNavUrl\s*=\s*reqUrl;/,
    'onReceivedError must record the failing main-frame URL',
  );
  // Recorded in the ordinary-failure branch, i.e. next to the PAUSE-022
  // signal — not in the external-scheme branches, which leave a rendered
  // page intact and cacheable.
  const idx = src.indexOf('failedNavUrl = reqUrl;');
  const after = src.slice(idx, idx + 400);
  assert.match(
    after,
    /MainFrameLoadSignal\.failed\(/,
    'the record must sit in the ordinary-failure branch',
  );
});

test('the record is cleared when the next navigation starts', () => {
  assert.match(
    src,
    /failedNavUrl\s*=\s*null;/,
    'onLoadStart must clear the failure record',
  );
  const idx = src.indexOf('failedNavUrl = null;');
  const before = src.slice(Math.max(0, idx - 400), idx);
  assert.match(
    before,
    /lastLoadStartUrl\s*=\s*url\?\.toString\(\);/,
    'the clear must happen in onLoadStart, not somewhere a failed page can '
      + 'still settle afterwards',
  );
});

test('the HtmlCache save is gated on the failure record', () => {
  const idx = src.indexOf('if (config.onHtmlLoaded != null');
  assert.ok(idx > 0, 'the onLoadStop cache-save condition must exist');
  const cond = src.slice(idx, src.indexOf('{', idx));
  assert.match(
    cond,
    /failedNavUrl\s*==\s*null/,
    'the cache save must skip a navigation that just failed, or the engine '
      + 'error page replaces the offline snapshot',
  );
});
