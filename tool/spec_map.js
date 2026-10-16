#!/usr/bin/env node
// Every requirement the specs declare and the checks that name it, strongest
// rung first: a model (TLC or TLAPS), an assert at the owner, a test, an
// integration test, a native test, a gate over source text. Printed, never
// committed; test/js/spec_verification.test.js holds the uncited ones to
// openspec/unverified.tsv.
//
//   node tool/spec_map.js            the map, one table per spec
//   node tool/spec_map.js --summary  the counts per spec
//   node tool/spec_map.js --json     the map as JSON
const { specMap, debt, KINDS } = require('../test/js/helpers/spec_map');

const { byId, checks, undeclared } = specMap();
const owed = debt();
const bySlug = new Map();
for (const req of byId.values()) {
  const list = bySlug.get(req.slug) ?? [];
  list.push(req);
  bySlug.set(req.slug, list);
}
const slugs = [...bySlug.keys()].sort();
const strongest = (id) => KINDS.find((k) => checks.get(id).has(k)) ?? null;

if (process.argv.includes('--json')) {
  const out = {};
  for (const [id, req] of byId) {
    out[id] = {
      title: req.title,
      spec: req.slug,
      checks: Object.fromEntries([...checks.get(id)].map(([k, v]) => [k, [...v].sort()])),
      owed: owed.get(id) ?? null,
    };
  }
  process.stdout.write(`${JSON.stringify(out, null, 2)}\n`);
  process.exit(0);
}

const total = byId.size;
const named = [...byId.keys()].filter((id) => checks.get(id).size > 0).length;
const rows = slugs.map((slug) => {
  const reqs = bySlug.get(slug);
  const tally = Object.fromEntries(KINDS.map((k) => [k, 0]));
  let cited = 0;
  for (const r of reqs) {
    const top = strongest(r.id);
    if (top) {
      cited++;
      tally[top]++;
    }
  }
  return { slug, count: reqs.length, cited, tally };
});

const head = `| Spec | Named / total | ${KINDS.join(' | ')} |\n|---|---|${KINDS.map(() => '---').join('|')}|`;
const summary = [
  `${named} of ${total} requirements are named by a check; ${total - named} are not.`,
  '',
  'Each requirement counts once, under the strongest kind of check that names it.',
  '',
  head,
  ...rows.map((r) => `| ${r.slug} | ${r.cited}/${r.count} | ${KINDS.map((k) => r.tally[k] || '').join(' | ')} |`),
];
if (undeclared.size > 0) {
  summary.push('', `Ids checks name that no spec declares: ${[...undeclared.keys()].sort().join(', ')}`);
}
if (process.argv.includes('--summary')) {
  process.stdout.write(`${summary.join('\n')}\n`);
  process.exit(0);
}

const out = [...summary];
for (const slug of slugs) {
  out.push('', `## ${slug}`, '', '| Requirement | Strongest | Named by |', '|---|---|---|');
  for (const r of bySlug.get(slug).sort((a, b) => a.id.localeCompare(b.id))) {
    const kinds = checks.get(r.id);
    const by = KINDS.filter((k) => kinds.has(k))
      .map((k) => `${k}: ${[...kinds.get(k)].sort().slice(0, 3).map((f) => `\`${f}\``).join(', ')}${kinds.get(k).size > 3 ? ` +${kinds.get(k).size - 3}` : ''}`)
      .join('; ');
    out.push(`| ${r.id} ${r.title.replace(/\|/g, '\\|')} | ${strongest(r.id) ?? 'none'} | ${by || (owed.has(r.id) ? `owed: ${owed.get(r.id)}` : '')} |`);
  }
}
process.stdout.write(`${out.join('\n')}\n`);
