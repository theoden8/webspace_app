// Structural gates for two boundaries whose behaviour cannot be reached from a
// headless test: a Flutter dialog, and a call site whose helper is unit-tested
// in isolation.
//
// 1. Site settings arriving from a QR code or a `webspace://qr/` link choose
//    that site's privacy posture - proxy, and whether tracking protection,
//    DNS blocking and content blocking are on. Applying them without showing
//    the user what they change lets a printed code or a link from any app add
//    a proxied, unprotected site. The review step is a dialog, so only its
//    presence in the flow can be asserted here.
//
// 2. The add-site preview resolves the typed hostname. `addSitePreviewMayResolveLocally`
//    is unit-tested directly, but that says nothing about whether the call site
//    still consults it - removing the guard left every test green.

const test = require('node:test');
const assert = require('node:assert');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

test('QR-supplied site settings are reviewed before the site is created', () => {
  const src = read('lib/main.dart');

  const confirm = src.indexOf('_confirmQrSiteSettings(resultQrSettings)');
  assert.ok(
    confirm !== -1,
    '_addSite no longer routes QR settings through _confirmQrSiteSettings; a scanned '
      + 'or linked payload would apply its proxy and protection changes unseen',
  );

  // The accept must gate the rest of the branch, not merely be logged.
  const after = src.slice(confirm, confirm + 400);
  assert.match(
    after,
    /if\s*\(!accepted[^)]*\)\s*return;/,
    'the QR review result is not acted on: _addSite must return when the user declines',
  );

  // Every QR entry point has to pass through _addSite to reach that review.
  assert.ok(
    !/webspace:\/\/qr\/[\s\S]{0,600}?_registerNewSite/.test(src),
    'the webspace://qr/ deep link reaches _registerNewSite without passing through '
      + '_addSite, bypassing the review dialog',
  );
});

test('the webspace://qr/ deep link is behind the link-handling switch', () => {
  const src = read('lib/main.dart');
  // Anchor on the inbound-URL path specifically. _handleShareIntent gates the
  // HTML-share path separately and earlier, so a bare indexOf would match that
  // one and keep passing however the QR branch moves.
  const consumed = src.indexOf('ShareIntentService.consumeLaunchUrl()');
  const qr = src.indexOf("raw.startsWith('webspace://qr/')");
  assert.ok(consumed !== -1 && qr !== -1, 'inbound-URL path or QR branch not found');
  assert.ok(consumed < qr, 'the QR branch no longer sits on the consumed-URL path');
  assert.match(
    src.slice(consumed, qr),
    /if \(!_linkHandlingEnabled\)/,
    'the QR branch runs before the _linkHandlingEnabled check on the inbound-URL '
      + 'path, so turning link handling off would not stop an inbound QR payload',
  );
});

test('the add-site preview only resolves hostnames when no proxy would', () => {
  const src = read('lib/screens/add_site.dart');
  const probe = src.indexOf('hostCanResolve(');
  assert.ok(probe !== -1, 'add_site.dart no longer probes hostnames');

  // Walk back to the enclosing condition and require the proxy guard in it.
  const before = src.slice(Math.max(0, probe - 400), probe);
  assert.match(
    before,
    /addSitePreviewMayResolveLocally\(\)/,
    'the hostname probe is no longer guarded by addSitePreviewMayResolveLocally(); '
      + 'with a proxy configured this leaks every site being added to the local resolver (LEAK-006)',
  );
});
