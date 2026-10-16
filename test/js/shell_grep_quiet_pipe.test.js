// Structural gate: no script pipes into `grep -q` (BUG-034).
//
// Under `pipefail`, which every script here sets (and GitHub does for a step
// that names `shell: bash`), `grep -q` exits at its first match and the
// writer upstream dies of SIGPIPE once its output passes the pipe buffer
// (64 KiB on Linux). The pipeline then fails, so a match reads as a miss, and
// only when the output is long: a TLC counterexample, a logcat dump, an APK
// listing. It passed locally and failed CI. A here-string
// (`grep -q pattern <<<"$out"`) has no writer to kill; in `sh`, which has no
// here-string, `| grep pattern >/dev/null` reads the whole input.
//
// Rung 5: no type sees into shell; a test over the source is the earliest
// point the pattern can be caught.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, files } = require('./helpers/source');

const scripts = () => [
  ...files('formal', /\.sh$/),
  ...files('scripts', /\.sh$/),
  ...files('tool', /\.sh$/),
  ...files('.github/workflows', /\.ya?ml$/),
];

const PIPE_INTO_QUIET_GREP = /\|\s*grep\s+(-[A-Za-z]*q[A-Za-z]*\b|--quiet\b)/;

test('no script pipes into grep -q', () => {
  const found = [];
  for (const file of scripts()) {
    read(file).split('\n').forEach((line, i) => {
      if (line.trim().startsWith('#')) return;
      if (PIPE_INTO_QUIET_GREP.test(line)) found.push(`${file}:${i + 1}: ${line.trim()}`);
    });
  }
  assert.deepEqual(found, [],
    'Match against a here-string, grep -q pattern <<<"$out", or in sh read '
        + 'the whole input: | grep pattern >/dev/null');
});

test('the gate sees the pattern it forbids', () => {
  assert.ok(PIPE_INTO_QUIET_GREP.test('echo "$out" | grep -qE "x"'));
  assert.ok(PIPE_INTO_QUIET_GREP.test('adb logcat -d | grep -qF -- "$p"'));
  assert.ok(PIPE_INTO_QUIET_GREP.test('x | grep --quiet y'));
  assert.ok(!PIPE_INTO_QUIET_GREP.test('grep -q y <<<"$out"'));
  assert.ok(!PIPE_INTO_QUIET_GREP.test('x | grep -m1 y'));
});
