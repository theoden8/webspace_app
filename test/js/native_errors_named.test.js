// A failure the Android code catches is named where it is caught, as perror
// names errno: the handler logs it, rethrows it or keeps it on a value the
// code reads, with its message, never its class alone. A dropped exception
// is how the router relay closed forum.snapcraft.io's tunnels for a day with
// nothing in the log to say why.
//
// Rung 5: nothing in this build checks Kotlin's handlers (no detekt), and a
// catch that drops its exception compiles. The Dart side is webspace_lints'
// catch_all rule. Teardown is exempt: `runCatching { x.close() }` (or a
// shutdown or cancel) on a resource already being let go, whose failure
// carries nothing.
const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, code, enclosed } = require('./helpers/source');

const ROOT = 'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/';
const TEARDOWN = /^[\w.?!()]+\.(close|shutdownInput|shutdownOutput|cancel|disconnect|release|interrupt)\(\)$/;

// Files that still drop a failure, and how many. Only shrinks: a file fixed
// leaves the list in the same change.
const DEBT = {
  'LocationPlugin.kt': 2,
  'MainActivity.kt': 5,
  'MediaPlaybackService.kt': 2,
  'NetworkSignInPlugin.kt': 1,
  'PasskeyPlugin.kt': 2,
  'ScreenShareService.kt': 4,
  'SurfaceDiagPlugin.kt': 2,
  'WebInterceptPlugin.kt': 2,
};

/** Each handler in `raw` (the text of `f`) that drops what it caught, as `line: why`. */
function dropped(f, raw = read(f)) {
  const masked = code(raw, { strings: true });
  const line = (i) => raw.slice(0, i).split('\n').length;
  const out = [];
  for (const m of masked.matchAll(/\bcatch\s*\(\s*(\w+)\s*:\s*[\w.]+\s*\)\s*\{/g)) {
    const name = m[1];
    const { body } = enclosed(raw, m.index + m[0].length - 1, '{', f);
    const uses = [...code(body, { strings: true }).matchAll(new RegExp(`\\b${name}\\b(\\.javaClass\\b)?`, 'g'))];
    const templated = new RegExp(`\\$${name}\\b`).test(code(body));
    if (uses.length === 0 && !templated) out.push(`${line(m.index)}: catch never reads ${name}`);
    else if (!templated && uses.every((u) => u[1])) out.push(`${line(m.index)}: catch names only ${name}'s class`);
  }
  for (const m of masked.matchAll(/\brunCatching\s*\{/g)) {
    const { body, close } = enclosed(raw, m.index + m[0].length - 1, '{', f);
    const next = masked.slice(close + 1).match(/^\s*\.(\w+)\s*\{?/);
    if (next && next[1] === 'onFailure') {
      const handler = enclosed(raw, close + 1 + next[0].length - 1, '{', f).body;
      if (/\bit\b|->/.test(code(handler, { strings: true }) + code(handler))) continue;
    }
    if (!next && TEARDOWN.test(code(body, { strings: true }).trim())) continue;
    out.push(`${line(m.index)}: runCatching ${next ? `.${next[1]}` : 'statement'} drops its failure`);
  }
  return out;
}

const found = Object.fromEntries(
  files(ROOT.replace(/\/$/, ''), /\.kt$/)
    .map((f) => [f.slice(ROOT.length), dropped(f)])
    .filter(([, hits]) => hits.length > 0),
);

test('every caught failure is named where it is caught', () => {
  const over = Object.entries(found)
    .filter(([f, hits]) => hits.length > (DEBT[f] ?? 0))
    .map(([f, hits]) => `${f}:\n    ${hits.join('\n    ')}`);
  assert.deepEqual(over, [], 'log it with describe(e), rethrow it, or keep it on a value the code reads');
});

test('the debt list only shrinks', () => {
  const stale = Object.entries(DEBT)
    .filter(([f, n]) => (found[f]?.length ?? 0) < n)
    .map(([f, n]) => `${f}: listed ${n}, now ${found[f]?.length ?? 0}`);
  assert.deepEqual(stale, [], 'lower the count, or drop the file from DEBT');
});

// The gate's own proof: the handlers it must catch, planted.
test('a dropped failure is caught (planted)', () => {
  const planted = (src) => dropped('planted.kt', src);
  assert.equal(planted('fun a() { try { b() } catch (e: java.io.IOException) { log("failed") } }').length, 1);
  assert.equal(planted('fun a() { try { b() } catch (e: java.io.IOException) { log("failed: ${e.javaClass.simpleName}") } }').length, 1);
  assert.equal(planted('fun a() { val x = runCatching { b() }.getOrNull() }').length, 1);
  assert.equal(planted('fun a() { runCatching { write(b) } }').length, 1);
  assert.deepEqual(planted('fun a() { try { b() } catch (e: java.io.IOException) { log("failed: ${describe(e)}") } }'), []);
  assert.deepEqual(planted('fun a() { try { b() } catch (e: java.io.IOException) { log("failed: $e") } }'), []);
  assert.deepEqual(planted('fun a() { runCatching { s.close() } }'), []);
  assert.deepEqual(planted('fun a() { runCatching { b() }.onFailure { log(describe(it)) } }'), []);
});
