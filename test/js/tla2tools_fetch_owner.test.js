// Structural gate: the TLC jar is fetched by formal/fetch_tla2tools.sh alone.
//
// Three scripts once fetched it with their own curl, and the copy in
// trace/check_trace.sh had no retries, so one 504 from the release CDN failed
// the trace check where check.sh would have retried. A second place naming
// the release is what this refuses (rung 5: a shell script has no type).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files, exists, lineAt } = require('./helpers/source');

const OWNER = 'formal/fetch_tla2tools.sh';
const RELEASE = /tlaplus\/tlaplus\/releases\/[^\s"']*tla2tools\.jar/g;

function fetches(rel, src) {
  return [...src.matchAll(RELEASE)].map((m) => `${rel}:${lineAt(src, m.index)}`);
}

test('only fetch_tla2tools.sh names the tla2tools release', () => {
  const found = ['formal', 'scripts', 'tool', '.github']
    .filter(exists)
    .flatMap((dir) => files(dir, /\.(?:sh|py|ya?ml)$/))
    .filter((rel) => rel !== OWNER)
    .flatMap((rel) => fetches(rel, read(rel)));
  assert.deepEqual(found, [], `fetch it with ${OWNER} <path>`);
  assert.ok(fetches(OWNER, read(OWNER)).length > 0, `${OWNER} must fetch it`);
  assert.match(read(OWNER), /curl [^\n]*--retry \d/, 'and retry a failed fetch');
});

test('planted: a script fetching the jar itself is caught', () => {
  const planted = 'curl -fsSL -o "$JAR" \\\n  https://github.com/tlaplus/tlaplus/releases/latest/download/tla2tools.jar\n';
  assert.deepEqual(fetches('planted.sh', planted), ['planted.sh:2']);
});
