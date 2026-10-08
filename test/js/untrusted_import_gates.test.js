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
const { read } = require('./helpers/source');

test('QR-supplied site settings are reviewed before the site is created', () => {
  const src = read('lib/controllers/site_editing_controller.dart');

  const confirm = src.indexOf('_prompts.reviewQrSettings(resultQrSettings)');
  assert.ok(
    confirm !== -1,
    'addSite no longer routes QR settings through reviewQrSettings; a scanned '
      + 'or linked payload would apply its proxy and protection changes unseen',
  );

  // The accept must gate the rest of the branch, not merely be logged.
  const after = src.slice(confirm, confirm + 400);
  assert.match(
    after,
    /if\s*\(!accepted[^)]*\)\s*return;/,
    'the QR review result is not acted on: addSite must return when the user declines',
  );

  // Every QR entry point has to pass through addSite to reach that review.
  const links = read('lib/controllers/link_controller.dart');
  assert.ok(
    !/webspace:\/\/qr\/[\s\S]{0,600}?registerSite/.test(links),
    'the webspace://qr/ deep link registers a site without passing through '
      + 'addSite, bypassing the review dialog',
  );
  assert.match(
    links,
    /webspace:\/\/qr\/[\s\S]{0,200}?_host\.addSiteFromQr\(decoded\)/,
    'the webspace://qr/ deep link no longer hands its payload to the add-site flow',
  );
  assert.match(
    read('lib/screens/webspace_page.dart'),
    /Future<void> addSiteFromQr\([^)]*\)\s*=>\s*_s\._editing\.addSite\(deepLinkQrSettings: settings\);/,
    'the page answers a QR deep link with something other than addSite',
  );
});

test('the webspace://qr/ deep link is behind the link-handling switch', () => {
  const src = read('lib/controllers/link_controller.dart');
  // Anchor on the inbound-URL path specifically. handleShareIntent gates the
  // HTML-share path separately and earlier, so a bare indexOf would match that
  // one and keep passing however the QR branch moves.
  const consumed = src.indexOf('ShareIntentService.consumeLaunchUrl()');
  const qr = src.indexOf("raw.startsWith('webspace://qr/')");
  assert.ok(consumed !== -1 && qr !== -1, 'inbound-URL path or QR branch not found');
  assert.ok(consumed < qr, 'the QR branch no longer sits on the consumed-URL path');
  assert.match(
    src.slice(consumed, qr),
    /if \(!AppPref\.linkHandlingEnabled\.value\)/,
    'the QR branch runs before the linkHandlingEnabled check on the inbound-URL '
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
