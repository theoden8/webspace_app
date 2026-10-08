// Implementation files stay under 2000 lines (CLAUDE.md, Style).
//
// Past that a file is split by concern. The ones kept longer are monoliths
// that read best whole, each named in LONG with the reason. No type can say
// how long a file is, so this is a gate. Tests are exempt: a test file is a
// list of cases, and its length is the length of the list.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');

const LIMIT = 2000;
const CODE = /\.(dart|kt|java|swift|m|mm|h|c|cc|cpp|rs|js|mjs|cjs|ts|py|sh|tla)$/;
const TESTS = /^(test|integration_test|test_driver)\/|\/src\/(test|androidTest)\/|\/(Runner|Plugin)Tests\//;

// Implementation files allowed past LIMIT, each with why it reads best whole.
const LONG = new Map([]);

const tracked = execFileSync('git', ['ls-files'], { cwd: REPO, encoding: 'utf8' })
  .split('\n')
  .filter((rel) => CODE.test(rel) && !TESTS.test(rel));
const lines = (rel) => read(rel).split('\n').length - 1;

test('the scan sees the implementation files (self-check)', () => {
  assert.ok(tracked.length > 200, `only ${tracked.length} files scanned`);
  assert.ok(tracked.includes('lib/main.dart'));
  assert.ok(!tracked.some((rel) => rel.startsWith('test/')), 'tests are exempt');
});

test(`no implementation file is over ${LIMIT} lines without a reason`, () => {
  const over = tracked
    .filter((rel) => !LONG.has(rel))
    .map((rel) => [rel, lines(rel)])
    .filter(([, n]) => n > LIMIT)
    .map(([rel, n]) => `${rel}: ${n}`);
  assert.deepEqual(over, [],
    'split the file by concern, or name it in LONG with why it reads best whole');
});

test('every exemption is still needed', () => {
  const stale = [...LONG.keys()].filter((rel) => !tracked.includes(rel) || lines(rel) <= LIMIT);
  assert.deepEqual(stale, [], 'drop the LONG entry for a file that is gone or now fits');
});
