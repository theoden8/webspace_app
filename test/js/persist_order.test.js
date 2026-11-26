// The page's saves read what they write after their last await
// (WEBSPACE-005, formal/persist_order.tla).
//
// An edit fires its save without waiting for it, so saves overlap and
// nothing orders them. formal/persist_order.tla shows that is safe exactly
// when each save reads the live state after its await and hands it to the
// write in the same turn ("live"), and that a save reading before its await
// writes an older state back over a newer one ("snapshot"). This gate holds
// the stores to the live save: a value a write takes from a local is
// declared after the last await before the write.
//
// Rung 5: a SharedPreferences write is not the model's state, so the
// analyzer's model_await rule, which holds a read of that state across an
// await, does not see it. A store whose saves wrote through a type that
// read the state at write time would lift this.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const STORES = [
  'lib/controllers/shell_store.dart',
  'lib/controllers/site_list_store.dart',
];

// Each `Future<void> save...(` method's name and body.
function saveMethods(source) {
  const out = [];
  const head = /Future<void>\s+(save\w*)\s*\([^)]*\)\s*async\s*\{/g;
  for (const m of source.matchAll(head)) {
    let depth = 1;
    let i = m.index + m[0].length;
    for (; depth > 0 && i < source.length; i++) {
      if (source[i] === '{') depth++;
      if (source[i] === '}') depth--;
    }
    out.push({ name: m[1], body: source.slice(m.index + m[0].length, i - 1) });
  }
  return out;
}

// Each write in [body] whose value is a local declared before the last
// await that precedes the write: what the live save forbids.
function staleWrites(body) {
  const stale = [];
  const write = /prefs\.(set\w+)\(\s*('[^']+'|\w+)\s*,\s*([A-Za-z_]\w*)\s*\)/g;
  for (const w of body.matchAll(write)) {
    const [, call, key, local] = w;
    const before = body.slice(0, w.index);
    // The await that prefixes this write is the write's own.
    const own = before.replace(/await\s*$/, '');
    const lastAwait = own.lastIndexOf('await ');
    const decl = new RegExp(
      `(?:final|var|List<\\w+>|[A-Z]\\w*(?:<[^>]*>)?)\\s+${local}\\s*=`);
    const d = decl.exec(own);
    if (d && d.index < lastAwait) stale.push(`${call}(${key}, ${local})`);
  }
  return stale;
}

test('every save of the page reads what it writes after its last await '
    + '(WEBSPACE-005)', () => {
  let writes = 0;
  for (const rel of STORES) {
    const methods = saveMethods(read(rel));
    assert.ok(methods.length > 0, `${rel}: no save method found`);
    for (const { name, body } of methods) {
      writes += (body.match(/prefs\.(set\w+|remove)\(/g) || []).length;
      assert.deepEqual(staleWrites(body), [],
        `${rel} ${name}: a write takes a value read before an await, so an `
        + 'older save landing after a newer one writes the older state back '
        + '(formal/persist_order.tla, "snapshot")');
    }
  }
  assert.ok(writes >= 6, `only ${writes} writes found: the gate reads nothing`);
});

// The planted mistake: saveWebspaces building its JSON before its await.
test('a save that reads before its await is caught', () => {
  const shell = read('lib/controllers/shell_store.dart');
  const [save] = saveMethods(shell).filter((m) => m.name === 'saveWebspaces');
  assert.ok(save, 'saveWebspaces not found');
  assert.deepEqual(staleWrites(save.body), []);
  const moved = save.body
    .replace(/\s*SharedPreferences prefs = await SharedPreferences\.getInstance\(\);/, '')
    .replace(/(await prefs\.setStringList)/,
      'SharedPreferences prefs = await SharedPreferences.getInstance();\n    $1');
  assert.notEqual(moved, save.body, 'the plant changed nothing');
  assert.deepEqual(staleWrites(moved), ["setStringList('webspaces', webspacesJson)"]);
});

// The planted mistake in the site list: its JSON built before the cookie
// store's lock is awaited.
test('a site list save that builds its JSON before an await is caught', () => {
  const list = read('lib/controllers/site_list_store.dart');
  const [save] = saveMethods(list).filter((m) => m.name === 'save');
  assert.ok(save, 'SiteListStore.save not found');
  assert.deepEqual(staleWrites(save.body), []);
  const json = /\n\s*final webViewModelsJson = [\s\S]*?\.toList\(\);/.exec(save.body);
  assert.ok(json, 'the site list JSON not found');
  const moved = save.body.replace(json[0], '').replace(
    /(\n\s*await cookies\.saveCookiesBuilt)/, `${json[0]}$1`);
  assert.deepEqual(staleWrites(moved), ['setStringList(_key, webViewModelsJson)']);
});
