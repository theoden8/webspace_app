// Structural gate: the process-wide proxy override is never asked for with
// an empty rule list (BUG-014 instance 6).
//
// On Android `ProxyController.setProxyOverride` is handed a `ProxySettings`
// whose `proxyRules` the fork loops into a `ProxyConfig.Builder`. A rule
// Chromium cannot parse throws out of `AwProxyController`, which is loud and
// leaves the previous override in place. An EMPTY list does not: it builds a
// config with no rules at all, native installs it, the listener reports
// success, and every WebView in the process goes direct while the Dart side
// logs "Applied proxy override". That is Apple's cleared-store shape
// (`setProxyConfigurations:` routes an empty array to `clearProxyConfigData`)
// arriving through a different door.
//
// The app cannot produce one today: each call site passes exactly one rule it
// built from a validated `host:port`. This gate is what keeps that true. The
// empty list would arrive the moment a call site builds its rules by mapping
// over a collection -- a per-site list, a bypass-aware rule set -- where every
// element can fail to convert. If that is what you are writing, do not delete
// this test: refuse the override when the list comes out empty, and make the
// caller fail closed the way `applyRouterOverride` does.

const test = require('node:test');
const assert = require('node:assert/strict');
const { callSites, enclosed } = require('./helpers/source');

const sites = callSites('.setProxyOverride');

test('the app still sets a process-wide proxy override', () => {
  // Guards the scan: if the call moves or is renamed, the assertions below
  // would pass while checking nothing.
  assert.ok(
    sites.length > 0,
    'no setProxyOverride call found under lib/; has the Android proxy path ' +
      'moved? Point this gate at it rather than deleting it',
  );
});

test('every proxy override names at least one rule', () => {
  for (const site of sites) {
    const where = `${site.file}:${site.line}`;
    assert.ok(site.args, `${where}: could not read the call's arguments`);
    assert.match(
      site.args,
      /proxyRules:\s*\[/,
      `${where} calls setProxyOverride without a proxyRules list. An override ` +
        'with no rules is not a no-op: it installs "no proxy" process-wide ' +
        'and reports success (BUG-014 instance 6)',
    );
    const list = enclosed(site.args, site.args.indexOf('proxyRules:'), '[').body;
    assert.ok(
      list !== null && /ProxyRule\s*\(/.test(list),
      `${where} builds its proxyRules without a literal ProxyRule. If the ` +
        'list is computed, refuse the override when it comes out empty and ' +
        'fail the caller closed -- an empty list silently unproxies every ' +
        'WebView in the process (BUG-014 instance 6)',
    );
  }
});
