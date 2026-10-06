// Structural gate: the egress allowlist stays a coverage claim (INTEG-016).
//
// scripts/egress_allowlist.txt is the one file that can turn an
// unallowlisted request into a passing CI run, so the cheapest way for the
// gate to rot is a line added to get a red build green. A permission
// nobody wrote a reason for is exactly the missing coverage-matrix row
// LEAK-007 is about.
//
// Three things are checked: entries parse the way egress_report.py parses
// them, every entry carries an inline justification, and the workflow
// still wires the guard into the Linux integration job at all.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const ALLOWLIST = 'scripts/egress_allowlist.txt';
const lines = read(ALLOWLIST).split('\n');

const entries = lines
  .map((text, i) => ({ text, line: i + 1 }))
  .filter(({ text }) => text.trim() && !text.trim().startsWith('#'));

test('every allowlist entry is one of the three known forms', () => {
  for (const { text, line } of entries) {
    const entry = text.split('#')[0].trim();
    assert.match(
      entry,
      /^(dns|host|ip):\S+$/,
      `${ALLOWLIST}:${line}: ${JSON.stringify(entry)} is not `
        + 'dns:<suffix>, host:<suffix> or ip:<addr|cidr>',
    );
  }
});

test('every allowlist entry says why that destination may be contacted', () => {
  for (const { text, line } of entries) {
    const comment = text.includes('#') ? text.split('#').slice(1).join('#') : '';
    assert.ok(
      comment.trim().length >= 10,
      `${ALLOWLIST}:${line}: ${JSON.stringify(text.trim())} has no `
        + 'justification. Name the code path that makes the request and why '
        + 'it may leave the runner (LEAK-007), or delete the entry.',
    );
  }
});

test('the Linux integration job still arms the guard', () => {
  const workflow = read('.github/workflows/build-and-test.yml');
  for (const needle of [
    'scripts/egress_guard_arm.sh',
    'scripts/egress_guard_disarm.sh',
    'scripts/egress_report.py',
    '--cap-add=NET_ADMIN',
  ]) {
    assert.ok(
      workflow.includes(needle),
      `build-and-test.yml no longer references ${needle}: the egress gate `
        + 'is wired out, so the allowlist above guarantees nothing.',
    );
  }
});
