#!/usr/bin/env node
// Holds an osv-scanner report of every locked dependency to
// docs/security/accepted_advisories.tsv: an advisory the scan reports that no
// row accepts fails, a row without a reason fails, and a row the scan no
// longer reports fails, so the list only shrinks. scripts/osv_scan.sh runs the
// scan and then this.
//
//   node tool/osv_check.js <report.json> <accepted_advisories.tsv>

const fs = require('node:fs');

/** Each advisory the report lists, by advisory id and package name. */
function findings(report) {
  const out = [];
  for (const result of report.results ?? []) {
    for (const p of result.packages ?? []) {
      for (const v of p.vulnerabilities ?? []) {
        out.push({
          id: v.id,
          pkg: p.package.name,
          version: p.package.version,
          ecosystem: p.package.ecosystem,
          source: result.source?.path ?? '',
          summary: v.summary ?? '',
        });
      }
    }
  }
  return out;
}

/** The accepted rows, a header first: `advisory\tpackage\treason`. */
function accepted(tsv) {
  return tsv.split('\n').slice(1).filter((l) => l.trim() && !l.startsWith('#')).map((l) => {
    const [id, pkg, reason] = l.split('\t');
    return { id, pkg, reason: reason ?? '' };
  });
}

const key = (id, pkg) => `${id} ${pkg}`;

/** What the report and the accepted list disagree on, one line each. */
function problems({ report, tsv }) {
  const out = [];
  const found = findings(report);
  const rows = accepted(tsv);
  const ok = new Set(rows.map((r) => key(r.id, r.pkg)));
  for (const f of found) {
    if (!ok.has(key(f.id, f.pkg))) {
      out.push(`${f.id} in ${f.ecosystem} ${f.pkg} ${f.version} (${f.source}): ${f.summary}; update the dependency, or accept it with why it cannot reach the app`);
    }
  }
  const reported = new Set(found.map((f) => key(f.id, f.pkg)));
  for (const r of rows) {
    if (!r.reason.trim()) out.push(`${r.id} in ${r.pkg} is accepted without a reason`);
    if (!reported.has(key(r.id, r.pkg))) out.push(`${r.id} in ${r.pkg} is no longer reported; delete its row`);
  }
  return out;
}

module.exports = { findings, accepted, problems };

if (require.main === module) {
  const [reportPath, tsvPath] = process.argv.slice(2);
  const found = problems({
    report: JSON.parse(fs.readFileSync(reportPath, 'utf8')),
    tsv: fs.readFileSync(tsvPath, 'utf8'),
  });
  if (found.length > 0) {
    process.stderr.write(`${found.join('\n')}\n`);
    process.exit(1);
  }
  process.stdout.write('every advisory the scan reports is accepted with a reason\n');
}
