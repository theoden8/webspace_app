// LICENSE-002 over the repo: no tracked file is a copy of copyleft data the
// app downloads, read by the detectors tool/check_artifact_licences.js reads
// a built app with (test/js/helpers/licences.js); artifact_licences.test.js
// plants a copy of each list for them, and a hand-made sample beside it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const { execFileSync } = require('node:child_process');
const L = require('./helpers/licences');
const { REPO, abs } = require('./helpers/source');

test('LICENSE-002 no copy of a list the app downloads is committed', () => {
  const copies = [];
  for (const rel of execFileSync('git', ['ls-files'], { cwd: REPO, encoding: 'utf8' }).split('\n').filter(Boolean)) {
    if (!fs.statSync(abs(rel), { throwIfNoEntry: false })?.isFile()) continue;
    const buf = fs.readFileSync(abs(rel));
    if (buf.subarray(0, 8000).includes(0)) continue;
    for (const name of L.copyleftDataIn(buf.toString('utf8'))) copies.push(`${rel}: a copy of ${name}`);
  }
  assert.deepEqual(copies, [], 'the app downloads these on the device (LICENSE-002)');
});
