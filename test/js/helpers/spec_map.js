// Every requirement the specs declare, and every check that names one: the
// map tool/spec_map.js prints and test/js/spec_verification.test.js holds
// to its debt list. A check names a requirement by its id anywhere in its
// text (a test's name, a model's action, a gate's message); in lib/ only an
// assert's message counts, since a doc comment catches nothing.

const { read, exists, files, dartFiles, code, enclosed } = require('./source');

// A requirement id: a prefix of one or more upper-case words, a three-digit
// number, then an optional letter (`DESIGN-002a`) or platform (`NOTIF-005-A`).
const ID = /(?<![A-Za-z0-9-])((?:[A-Z][A-Z0-9]*-)+\d{3}(?![0-9])(?:[a-z](?![A-Za-z0-9])|-[A-Z](?![A-Za-z0-9]))?)/g;
// `PAUSE-015/017/018`: one prefix, several numbers.
const LIST = /(?<![A-Za-z0-9-])((?:[A-Z][A-Z0-9]*-)+)\d{3}((?:\/\d{3})+)(?![0-9])/g;

/** Every id [text] names, a slash list read as each of its numbers. */
function idsIn(text) {
  const out = [...text.matchAll(ID)].map((m) => m[1]);
  for (const m of text.matchAll(LIST)) {
    for (const n of m[2].split('/').slice(1)) out.push(m[1] + n);
  }
  return out;
}

// Tokens shaped like an id that name a standard, not a requirement.
const NOT_REQUIREMENTS = new Map([['ISO-639', 'the language-code standard']]);

const HEADER = /^###\s+Requirement:\s*((?:[A-Z][A-Z0-9]*-)+\d{3}(?:[a-z]|-[A-Z])?)\b\s*[-—:]?\s*(.*)$/gm;

/** The spec files a requirement may live in: published, or a change in flight. */
function specFiles() {
  const out = files('openspec/specs', /^spec\.md$/);
  for (const f of files('openspec/changes', /^spec\.md$/)) {
    if (!f.startsWith('openspec/changes/archive/')) out.push(f);
  }
  return out;
}

/** The capability a spec file describes: `openspec/.../specs/<slug>/spec.md`. */
const slugOf = (f) => f.split('/specs/')[1].split('/')[0];

/**
 * Every requirement by id: its title, its spec's slug and every file that
 * states it (a change may restate a published one). Headers that carry no
 * id are returned apart, as `unnamed`.
 */
function requirements() {
  const byId = new Map();
  const unnamed = [];
  for (const f of specFiles()) {
    const src = read(f);
    for (const m of src.matchAll(HEADER)) {
      const [, id, title] = m;
      const at = byId.get(id) ?? { id, title: title.trim(), slug: slugOf(f), files: [] };
      at.files.push(f);
      byId.set(id, at);
    }
    for (const m of src.matchAll(/^###\s+Requirement:\s*(.*)$/gm)) {
      if (!/^(?:[A-Z][A-Z0-9]*-)+\d{3}/.test(m[1])) unnamed.push({ file: f, title: m[1].trim() });
    }
  }
  return { byId, unnamed };
}

// The gate over this map plants ids of its own to show each rule catches
// its mistake; they cite nothing.
const SELF = 'test/js/spec_verification.test.js';

const optional = (dir, re) => (exists(dir) ? files(dir, re) : []);

/**
 * The tool/ scripts CI runs, directly or through an npm script: what the
 * workflows run is the one list of what checks, so none is kept here.
 */
function ciTools() {
  const scripts = JSON.parse(read('package.json')).scripts ?? {};
  const out = new Set();
  const take = (cmd) => {
    for (const m of cmd.matchAll(/\bnode\s+(tool\/\S+\.js)\b/g)) out.add(m[1]);
  };
  for (const wf of optional('.github/workflows', /\.ya?ml$/)) {
    const text = read(wf);
    take(text);
    for (const m of text.matchAll(/\bnpm run\s+([\w:-]+)/g)) take(scripts[m[1]] ?? '');
  }
  return [...out].filter(exists).sort();
}

/**
 * The checks, by kind. A JS test that reads lib/ source is a gate (rung 5);
 * one that runs a page script or a fixture is a boundary test (rung 4).
 */
function checkFiles() {
  const js = [...optional('test/js', /\.js$/), ...optional('test/browser', /\.js$/)];
  const isGate = (f) => f.endsWith('.test.js')
    && /read\(\s*['`"]lib\/|dartFiles\(|methodBody|findMethod|blockAfter\(/.test(read(f));
  return {
    model: [
      ...optional('formal', /\.(tla|cfg)$/).filter((f) => !f.includes('/states/')),
      ...optional('formal', /^check\.sh$/),
      // The checks activation.tla runs, each a value printed as a config.
      ...optional('test/formal_model', /^checks\.dart$/),
    ],
    test: [...optional('test', /\.dart$/).filter((f) => !f.startsWith('test/formal_model/')), ...js.filter((f) => !isGate(f) && f !== SELF)],
    gate: js.filter((f) => isGate(f) && f !== SELF),
    integration: optional('integration_test', /\.dart$/),
    native: [
      ...optional('android/app/src/test', /\.kt$/),
      ...optional('android/app/src/androidTest', /\.kt$/),
      ...optional('ios/RunnerTests', /\.swift$/),
      ...optional('macos/RunnerTests', /\.swift$/),
    ],
    tool: ciTools(),
  };
}

/** The ids an assert in a Dart file names in its condition or message. */
function assertIds(rel) {
  const raw = read(rel);
  if (raw.search(ID) === -1) return [];
  const out = [];
  for (const m of code(raw).matchAll(/\bassert\s*\(/g)) {
    const { body } = enclosed(raw, m.index + m[0].length - 1, '(', rel);
    out.push(...idsIn(body));
  }
  return out;
}

/**
 * Every id each check names: `Map<id, Map<kind, Set<file>>>`. The prefixes a
 * spec uses bound what counts, so `UTF-8` or `BUG-007` is no citation.
 */
function citations({ prefixes }) {
  const cited = new Map();
  const note = (id, kind, file) => {
    const prefix = id.replace(/-\d{3}.*$/, '');
    if (!prefixes.has(prefix) || NOT_REQUIREMENTS.has(id)) return;
    const kinds = cited.get(id) ?? new Map();
    const where = kinds.get(kind) ?? new Set();
    where.add(file);
    kinds.set(kind, where);
    cited.set(id, kinds);
  };
  for (const [kind, list] of Object.entries(checkFiles())) {
    for (const f of list) {
      for (const id of idsIn(read(f))) note(id, kind, f);
    }
  }
  for (const f of dartFiles()) {
    for (const id of assertIds(f)) note(id, 'assert', f);
  }
  return cited;
}

/**
 * A cited id resolves to the requirement of that id, or, when only its
 * platform or lettered parts are declared (`NOTIF-005` for `-A` and `-I`),
 * to all of them.
 */
function resolve(id, byId) {
  if (byId.has(id)) return [id];
  return [...byId.keys()].filter((k) => k.startsWith(`${id}-`) || new RegExp(`^${id}[a-z]$`).test(k));
}

/** The kinds that verify a requirement, strongest rung first. */
const KINDS = ['model', 'assert', 'test', 'integration', 'native', 'tool', 'gate'];

/**
 * The whole map: each requirement with the checks that name it, and the
 * cited ids no spec declares.
 */
function specMap() {
  const { byId, unnamed } = requirements();
  const prefixes = new Set([...byId.keys()].map((id) => id.replace(/-\d{3}.*$/, '')));
  const cited = citations({ prefixes });
  const checks = new Map([...byId.keys()].map((id) => [id, new Map()]));
  const undeclared = new Map();
  for (const [id, kinds] of cited) {
    const targets = resolve(id, byId);
    if (targets.length === 0) {
      undeclared.set(id, kinds);
      continue;
    }
    for (const t of targets) {
      for (const [kind, where] of kinds) {
        const into = checks.get(t).get(kind) ?? new Set();
        for (const f of where) into.add(f);
        checks.get(t).set(kind, into);
      }
    }
  }
  return { byId, unnamed, checks, undeclared };
}

/**
 * What the gate refuses, from a map and the debt list: a header with no id,
 * an id two requirements share, a requirement no check names and the list
 * does not owe, a listed one a check now names, a listed id no spec
 * declares or that says no reason, and a citation of an undeclared id.
 */
function problems({ byId, unnamed, checks, undeclared }, owed) {
  const named = (id) => (checks.get(id)?.size ?? 0) > 0;
  return {
    unnamed: unnamed.map((u) => `${u.file}: ${u.title}`),
    shared: [...byId.values()]
      .filter((r) => new Set(r.files).size < r.files.length
        || new Set(r.files.map(slugOf)).size > 1)
      .map((r) => `${r.id}: ${r.files.join(', ')}`),
    unowned: [...byId.keys()].filter((id) => !named(id) && !owed.has(id)),
    paid: [...owed.keys()].filter((id) => byId.has(id) && named(id)),
    unknown: [...owed.keys()].filter((id) => !byId.has(id)),
    bare: [...owed].filter(([, why]) => !why).map(([id]) => id),
    undeclared: [...undeclared.keys()].sort(),
  };
}

const DEBT = 'openspec/unverified.tsv';

/** The debt list: id, then why no check names it yet. */
function debt() {
  if (!exists(DEBT)) return new Map();
  const out = new Map();
  for (const line of read(DEBT).split('\n')) {
    if (!line.trim() || line.startsWith('#')) continue;
    const [id, reason = ''] = line.split('\t');
    out.set(id.trim(), reason.trim());
  }
  return out;
}

module.exports = { specMap, debt, problems, resolve, idsIn, DEBT, KINDS, ID };
