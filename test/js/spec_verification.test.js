// Every requirement a spec declares is named by a check that verifies it (a
// test, a model or proof, an assert at its owner, a gate), or listed in
// openspec/unverified.tsv with why no check does yet; the list only shrinks.
// Rung 5: a test cites a requirement in its text, since no type can say which
// requirement a test verifies. tool/spec_map.js prints the whole map.
const test = require('node:test');
const assert = require('node:assert/strict');
const { specMap, debt, problems, resolve, idsIn, DEBT } = require('./helpers/spec_map');

const map = specMap();
const found = problems(map, debt());

test('every requirement header carries an id', () => {
  assert.deepEqual(found.unnamed, [], 'give each requirement the next free id of its spec');
});

test('no id names two requirements', () => {
  assert.deepEqual(found.shared, [], 'a citation of a shared id verifies neither; renumber one');
});

test('every requirement is named by a check or owed', () => {
  assert.deepEqual(found.unowned, [],
    `name each in the check that verifies it (a test's name, a model's action, an `
    + `assert's message), or list it in ${DEBT} with why no check does yet`);
});

test('the debt list only shrinks', () => {
  assert.deepEqual(found.paid, [], `a check names these now: drop them from ${DEBT}`);
});

test('the debt list owes declared requirements, each with its reason', () => {
  assert.deepEqual({ unknown: found.unknown, bare: found.bare }, { unknown: [], bare: [] });
});

test('a check names only requirements a spec declares', () => {
  assert.deepEqual(found.undeclared, [], 'a typo, or a requirement since renumbered or dropped');
});

test('an id is read in each of its shapes, and nothing else is one', () => {
  assert.deepEqual(
    idsIn('CB-006, NOTIF-005-A and DESIGN-002a; SHIM-TEST-001 (US-DR-005).'),
    ['CB-006', 'NOTIF-005-A', 'DESIGN-002a', 'SHIM-TEST-001', 'US-DR-005'],
  );
  assert.deepEqual(idsIn('UTF-8, ISO-8601, x-CB-006, CB-0061'), []);
  assert.deepEqual(idsIn('(PAUSE-015/017/018)'), ['PAUSE-015', 'PAUSE-017', 'PAUSE-018']);
});

test('each rule catches the mistake it is for', () => {
  const req = (id, files) => [id, { id, title: id, slug: files[0].split('/specs/')[1].split('/')[0], files }];
  const planted = {
    byId: new Map([
      req('CB-001', ['openspec/specs/content-blocker/spec.md']),
      req('CB-002', ['openspec/specs/content-blocker/spec.md']),
      req('CB-003', ['openspec/specs/content-blocker/spec.md', 'openspec/specs/content-blocker/spec.md']),
      req('LOC-001', ['openspec/specs/localization/spec.md', 'openspec/specs/per-site-location/spec.md']),
    ]),
    unnamed: [{ file: 'openspec/specs/content-blocker/spec.md', title: 'Lists' }],
    checks: new Map([
      ['CB-001', new Map([['test', new Set(['test/a_test.dart'])]])],
      ['CB-002', new Map()],
      ['CB-003', new Map()],
      ['LOC-001', new Map([['gate', new Set(['test/js/b.test.js'])]])],
    ]),
    undeclared: new Map([['CB-099', new Map()]]),
  };
  const owed = new Map([['CB-001', 'covered since'], ['CB-404', 'gone'], ['CB-003', '']]);
  assert.deepEqual(problems(planted, owed), {
    unnamed: ['openspec/specs/content-blocker/spec.md: Lists'],
    shared: [
      'CB-003: openspec/specs/content-blocker/spec.md, openspec/specs/content-blocker/spec.md',
      'LOC-001: openspec/specs/localization/spec.md, openspec/specs/per-site-location/spec.md',
    ],
    unowned: ['CB-002'],
    paid: ['CB-001'],
    unknown: ['CB-404'],
    bare: ['CB-003'],
    undeclared: ['CB-099'],
  });
});

test('a family id names each of its parts', () => {
  const byId = new Map([['NOTIF-005', {}], ['NOTIF-005-A', {}], ['NOTIF-005-I', {}], ['US-001b', {}]]);
  assert.deepEqual(resolve('NOTIF-005', byId), ['NOTIF-005']);
  assert.deepEqual(resolve('US-001', byId), ['US-001b']);
  assert.deepEqual(resolve('CB-001', byId), []);
});
