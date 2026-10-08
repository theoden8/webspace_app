// One funnel for every change to the set of sites (`_commitSites`).
//
// Which steps a change needs is decided in `SiteSetChange.effects`, an
// exhaustive switch the compiler holds every new kind to, and tested in
// test/site_runtime_test.dart. What no type can say is the order the steps
// run in, and that nothing else writes the list. This gate holds both:
//
//   - LIR-023: a deleted site's hosted tabs close before its container goes.
//   - ARCH-010: open archives seal before an import replaces their rows.
//   - LIR-017 / LIR-031 before ARCH-001's archive record: references settle
//     before the archived copy is taken, and that copy is written before the
//     app tier drops the site.
//   - TOR-002: the refcount is reconciled ahead of the demo-mode bail.

const test = require('node:test');
const assert = require('node:assert/strict');
const { methodBody, dartFiles, read, code } = require('./helpers/source');

const commit = methodBody('_commitSites');

function inOrder(body, steps, what) {
  let at = -1;
  for (const step of steps) {
    const next = body.indexOf(step, at + 1);
    assert.ok(next > at, `${what}: ${step} is missing or out of order`);
    at = next;
  }
}

test('the funnel runs its steps in one fixed order', () => {
  inOrder(commit, [
    'switch (change)',
    '_sites.apply(change)',
    '_assignContainerColors()',
    '_links.pruneOutboundPreferences()',
    '_tabs.reconcileLinkTabs()',
    '_tabs.closeIneligibleHostedTabs()',
    '_archives.recordIn(',
    '_activation.setCurrentIndex(null)',
    '_network.syncTorHolders()',
    '_network.refreshRoutes()',
    '_persistSites()',
    '_shell.saveWebspaces()',
    '_background.reschedule()',
    '_sweep.afterRemoval()',
  ], '_commitSites');
});

test('removals and imports prepare before anything moves', () => {
  const before = commit.slice(0, commit.indexOf('_sites.apply(change)'));
  assert.match(before, /case SiteRemoved\(:final site\):\s*await _retireSite\(site\);/);
  assert.match(before, /case SitesReplaced\(\):\s*await _archives\.closeAll\(\);/,
    'an import seals open archives before their rows go (ARCH-010)');
});

test('a deleted site\'s hosted tabs close before its container goes (LIR-023)', () => {
  inOrder(methodBody('_retireSite'), [
    '_tabs.closeIneligibleHostedTabs(goneSiteId: site.siteId)',
    '_containerIsolation.onSiteDeleted(site.siteId)',
  ], '_retireSite');
});

test('only the funnel writes the site list', () => {
  const writes = /\.models\s*(\.\.)?\.?\s*(add|addAll|insert|remove|removeAt|removeWhere|clear)\(/g;
  const offenders = [];
  for (const rel of dartFiles('lib')) {
    if (rel === 'lib/controllers/site_runtime.dart') continue;
    const src = code(read(rel));
    for (const m of src.matchAll(writes)) {
      offenders.push(`${rel}:${src.slice(0, m.index).split('\n').length}`);
    }
  }
  assert.deepEqual(offenders, [],
    'mutate the list through _commitSites (SiteRuntime.apply)');
});
