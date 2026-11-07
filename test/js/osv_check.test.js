// tool/osv_check.js holds an osv-scanner report to
// docs/security/accepted_advisories.tsv. The scan needs network, so CI runs
// it (scripts/osv_scan.sh); here each rule of the check is shown catching the
// mistake it exists for, on a report shaped as osv-scanner writes one.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');
const { problems, accepted } = require('../../tool/osv_check');

const report = (...entries) => ({
  results: [{
    source: { path: 'package-lock.json' },
    packages: entries.map(([pkg, id]) => ({
      package: { name: pkg, version: '1.0.0', ecosystem: 'npm' },
      vulnerabilities: [{ id, summary: 'planted' }],
    })),
  }],
});
const tsv = (...rows) => ['advisory\tpackage\treason', ...rows.map((r) => r.join('\t'))].join('\n');

test('a report whose every advisory is accepted with a reason passes', () => {
  assert.deepEqual(problems({ report: report(['left-pad', 'GHSA-aaaa']), tsv: tsv(['GHSA-aaaa', 'left-pad', 'unreachable']) }), []);
});

test('an advisory no row accepts fails', () => {
  const found = problems({ report: report(['left-pad', 'GHSA-aaaa']), tsv: tsv() });
  assert.ok(found.some((p) => p.startsWith('GHSA-aaaa in npm left-pad')), found.join('\n'));
});

test('a row accepting the advisory for another package does not cover it', () => {
  const found = problems({ report: report(['left-pad', 'GHSA-aaaa']), tsv: tsv(['GHSA-aaaa', 'right-pad', 'unreachable']) });
  assert.ok(found.some((p) => p.startsWith('GHSA-aaaa in npm left-pad')), found.join('\n'));
});

test('a row without a reason fails', () => {
  const found = problems({ report: report(['left-pad', 'GHSA-aaaa']), tsv: tsv(['GHSA-aaaa', 'left-pad', ' ']) });
  assert.ok(found.some((p) => /accepted without a reason/.test(p)), found.join('\n'));
});

test('a row the scan no longer reports fails, so the list only shrinks', () => {
  const found = problems({ report: report(), tsv: tsv(['GHSA-aaaa', 'left-pad', 'unreachable']) });
  assert.ok(found.some((p) => /no longer reported; delete its row/.test(p)), found.join('\n'));
});

test('every accepted advisory in the repository carries a reason', () => {
  for (const row of accepted(read('docs/security/accepted_advisories.tsv'))) {
    assert.ok(row.reason.trim().length > 20, `${row.id} in ${row.pkg} needs a reason that says why it cannot reach the app`);
  }
});
