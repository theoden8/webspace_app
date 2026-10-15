// One funnel for every change to the set of sites (`SiteSetCommit`).
//
// Which steps a change needs is `SiteSetChange.effects`, an exhaustive switch
// tested in test/site_runtime_test.dart; the order the funnel runs them in is
// test/site_set_commit_test.dart, and a delete's order (LIR-023) is
// test/site_deletion_test.dart and the delete world of formal/activation.tla.
// What no test can drive is that nothing else writes the list.

const test = require('node:test');
const assert = require('node:assert/strict');
const { dartFiles, read, code } = require('./helpers/source');

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
    'mutate the list through SiteSetCommit (SiteRuntime.apply)');
});
