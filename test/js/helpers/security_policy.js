// docs/security/policy.md read as data: each rule of the access policy, the
// code that owns it and the requirements that state it. How strongly each
// requirement is checked is tool/spec_map.js's to say, never this file's;
// what a rule owes until a model or a type proves it is
// docs/security/policy_debt.tsv, which only shrinks.
// test/js/security_policy.test.js holds both.

const { read, exists } = require('./source');
const { resolve, idsIn } = require('./spec_map');

const POLICY = 'docs/security/policy.md';
const DEBT = 'docs/security/policy_debt.tsv';

// The kinds of check that prove a requirement rather than give evidence for
// it: a model, a compile probe (spec_map's `type`) or an analyzer rule at
// error severity. An assert, a test or a gate is evidence.
const PROVES = new Set(['model', 'type', 'analyzer']);

// A debt row for a gap no requirement states yet.
const UNSTATED = '-';

/** The `## Rules` table: `| Rule | Allowed | Owner | Requirements |`. */
function rules(text) {
  const out = [];
  let inRules = false;
  let seenHeader = false;
  for (const line of text.split('\n')) {
    const h = /^##\s+(.+?)\s*$/.exec(line);
    if (h) {
      inRules = h[1] === 'Rules';
      seenHeader = false;
      continue;
    }
    if (!inRules || !line.startsWith('|')) continue;
    const cells = line.slice(1, -1).split('|').map((c) => c.trim());
    if (!seenHeader) {
      seenHeader = true;
      continue;
    }
    if (cells.every((c) => /^:?-+:?$/.test(c))) continue;
    const [rule, allowed, owner, reqs] = cells;
    const label = rule.replace(/[`*]/g, '');
    out.push({
      rule: /^R\d+\b/.exec(label)?.[0] ?? label,
      allowed,
      owners: [...owner.matchAll(/`([^`]+)`/g)].map((m) => m[1]),
      ids: idsIn(reqs ?? ''),
    });
  }
  return out;
}

/**
 * The debt rows, a header first: `requirement\trule\towed\tgap\tclosed by`,
 * where `owed` is the kind of check that will close it, `model` or `type`.
 */
function debt(tsv) {
  return tsv.split('\n').slice(1).filter((l) => l.trim() && !l.startsWith('#')).map((l) => {
    const [requirement, rule, owed, gap, closedBy] = l.split('\t');
    return { requirement, rule, owed, gap, closedBy };
  });
}

/** The strongest kind of check spec_map finds for [id], or null for none. */
function strongest(id, { byId, checks, kinds }) {
  const found = new Set();
  for (const t of resolve(id, byId)) {
    for (const k of checks.get(t)?.keys() ?? []) found.add(k);
  }
  return kinds.find((k) => found.has(k)) ?? null;
}

/**
 * What the policy and its debt claim that the repository does not bear
 * out, one line each. [map] is spec_map's: every requirement, the checks
 * that name each, and its kinds strongest first.
 */
function problems({ text, tsv, map }) {
  const out = [];
  const listed = rules(text);
  if (listed.length === 0) return ['no "## Rules" table'];
  const ruleIds = new Set();
  listed.forEach((r, i) => {
    if (r.rule !== `R${i + 1}`) out.push(`rule ${i + 1} is "${r.rule}", not R${i + 1}: rules are numbered in order`);
    ruleIds.add(r.rule);
    if (r.owners.length === 0) out.push(`${r.rule} names no owner`);
    for (const f of r.owners) {
      if (!exists(f)) out.push(`${r.rule}: owner ${f} does not exist`);
    }
    if (r.ids.length === 0) out.push(`${r.rule} names no requirement`);
    for (const id of r.ids) {
      if (resolve(id, map.byId).length === 0) out.push(`${r.rule}: no spec declares ${id}`);
    }
  });

  const rows = debt(tsv);
  const owed = new Set();
  for (const row of rows) {
    if (!ruleIds.has(row.rule)) out.push(`debt row ${row.requirement} names no rule ${row.rule}`);
    if (!PROVES.has(row.owed)) out.push(`debt row ${row.requirement} (${row.rule}) is owed "${row.owed}", not one of ${[...PROVES].join(', ')}`);
    if (!row.gap?.trim() || !row.closedBy?.trim()) out.push(`debt row ${row.requirement} (${row.rule}) leaves its gap or what closes it empty`);
    if (row.requirement === UNSTATED) continue;
    const rule = listed.find((r) => r.rule === row.rule);
    if (rule && !rule.ids.includes(row.requirement)) out.push(`debt row ${row.requirement}: ${row.rule} does not name it`);
    if (PROVES.has(strongest(row.requirement, map))) {
      out.push(`debt row ${row.requirement}: a ${strongest(row.requirement, map)} check proves it now; delete the row`);
    }
    owed.add(row.requirement);
  }

  for (const r of listed) {
    for (const id of r.ids) {
      if (!PROVES.has(strongest(id, map)) && !owed.has(id)) {
        out.push(`${r.rule}: ${id} is checked by ${strongest(id, map) ?? 'nothing'}, which proves nothing, and no debt row says what closes it`);
      }
    }
  }
  return out;
}

/** The policy as it stands in the repository. */
const current = () => ({ text: read(POLICY), tsv: read(DEBT) });

module.exports = { POLICY, DEBT, PROVES, UNSTATED, rules, debt, strongest, problems, current };
