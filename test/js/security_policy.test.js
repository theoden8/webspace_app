// docs/security/policy.md names, for each rule of the access policy, the code
// that owns it and the requirements that state it; docs/security/policy_debt.tsv
// owes each requirement no model or compile probe proves yet, and only
// shrinks. Rung 5: which requirement states a rule is prose no type can hold,
// so the text is held to the specs and to spec_map's checks here. Every rule
// below is shown catching the mistake it exists for.
const test = require('node:test');
const assert = require('node:assert/strict');
const { specMap, KINDS } = require('./helpers/spec_map');
const { problems, current } = require('./helpers/security_policy');

const map = { ...specMap(), kinds: KINDS };
const policy = current();

/** [policy] with one edit, which must apply. */
function planted({ text = policy.text, tsv = policy.tsv }) {
  assert.ok(text !== policy.text || tsv !== policy.tsv, 'the planted edit did not apply');
  return problems({ text, tsv, map });
}

const edit = (src, from, to) => {
  assert.ok(src.includes(from), `"${from}" is not in the policy to plant a mistake on`);
  return src.replace(from, to);
};

test('the policy and its debt hold against the specs and their checks', () => {
  assert.deepEqual(problems({ ...policy, map }), []);
});

test('a rule citing a requirement no spec declares is caught', () => {
  // Built here so this file cites no undeclared id to spec_verification.
  const unknown = ['PERM', '999'].join('-');
  const found = planted({ text: edit(policy.text, '| PERM-001, PERM-002 |', `| PERM-001, PERM-002, ${unknown} |`) });
  assert.ok(found.some((p) => p.includes(`no spec declares ${unknown}`)), found.join('\n'));
});

test('an owner that does not exist is caught', () => {
  const found = planted({ text: edit(policy.text, '`lib/services/page_phase.dart`', '`lib/services/page_phases_gone.dart`') });
  assert.ok(found.some((p) => /owner lib\/services\/page_phases_gone\.dart does not exist/.test(p)), found.join('\n'));
});

test('rules out of order are caught', () => {
  const found = planted({ text: edit(policy.text, '| R2 grants |', '| R3 grants |') });
  assert.ok(found.some((p) => /not R2: rules are numbered in order/.test(p)), found.join('\n'));
});

test('a requirement nothing proves and no row owes is caught', () => {
  const row = policy.tsv.split('\n').find((l) => l.startsWith('PERM-002\t'));
  const found = planted({ tsv: edit(policy.tsv, `${row}\n`, '') });
  assert.ok(found.some((p) => /PERM-002 is checked by test, which proves nothing/.test(p)), found.join('\n'));
});

test('a row owing what a model already proves is caught, so the list only shrinks', () => {
  const found = planted({ tsv: `${policy.tsv}ISO-001\tR1\tmodel\tplanted\tplanted\n` });
  assert.ok(found.some((p) => /debt row ISO-001: a model check proves it now; delete the row/.test(p)), found.join('\n'));
});

test('a row owed a kind of check that proves nothing is caught', () => {
  const found = planted({ tsv: edit(policy.tsv, 'CONT-005\tR1\ttype\t', 'CONT-005\tR1\ttest\t') });
  assert.ok(found.some((p) => /CONT-005 \(R1\) is owed "test"/.test(p)), found.join('\n'));
});

test('a row for a requirement its rule does not name is caught', () => {
  const found = planted({ tsv: edit(policy.tsv, 'US-007\tR5\t', 'US-007\tR6\t') });
  assert.ok(found.some((p) => /debt row US-007: R6 does not name it/.test(p)), found.join('\n'));
});
