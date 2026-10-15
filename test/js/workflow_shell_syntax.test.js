// Structural gate: the shell blocks embedded in the CI workflow must parse.
//
// The Linux integration-test step wraps its whole loop in a single-quoted
// `bash -c '...'` string inside the YAML. That makes an apostrophe anywhere
// inside — including in a comment — terminate the string early, and the block
// dies at runtime with "syntax error: unexpected end of file". It cost a full
// CI cycle to find once (a comment reading "the WebView's own media gates"),
// and nothing in `yaml` validation or a Dart/JS test would catch it: the YAML
// is still well-formed, the damage is one layer down in the shell.
//
// This test extracts each embedded block and runs `bash -n` (parse only, no
// execution) over it, so the next stray quote fails here in seconds instead.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { read } = require('./helpers/source');

const WORKFLOW = '.github/workflows/build-and-test.yml';

// Pull out every `bash -c '` ... `'` block: the body runs from the line after
// the opener to the line whose only non-whitespace character is the closing
// quote.
function extractSingleQuotedShellBlocks(text) {
  const lines = text.split('\n');
  const blocks = [];
  for (let i = 0; i < lines.length; i++) {
    if (!/bash -c '\s*$/.test(lines[i])) continue;
    let end = -1;
    for (let j = i + 1; j < lines.length; j++) {
      if (lines[j].trim() === "'") { end = j; break; }
    }
    assert.notEqual(end, -1,
      `unterminated "bash -c '" block starting at ${WORKFLOW}:${i + 1}`);
    blocks.push({ startLine: i + 2, body: lines.slice(i + 1, end).join('\n') });
    i = end;
  }
  return blocks;
}

const workflowText = read(WORKFLOW);

/** A job's block: its header line up to the next job's. */
function job(text, id) {
  const start = text.indexOf(`\n  ${id}:\n`);
  assert.notEqual(start, -1, `${id} job not found`);
  const rest = text.slice(start + 1);
  const next = rest.search(/\n {2}[a-z][a-z-]*:\n/);
  return next === -1 ? rest : rest.slice(0, next);
}

const blocks = extractSingleQuotedShellBlocks(workflowText);

test('the workflow embeds at least one single-quoted shell block', () => {
  // Guards the extractor itself: if the workflow is restructured so no block
  // matches, the syntax assertions below would pass vacuously.
  assert.ok(blocks.length > 0,
    'found no `bash -c \'...\'` blocks — has the workflow changed shape?');
});

for (const block of blocks) {
  test(`shell block at ${WORKFLOW}:${block.startLine} parses`, () => {
    // An apostrophe inside would have ended the YAML-level quoting, so the
    // body we extracted can never legitimately contain one.
    const apostrophe = block.body.indexOf("'");
    if (apostrophe !== -1) {
      const line = block.body.slice(0, apostrophe).split('\n').length;
      const text = block.body.split('\n')[line - 1];
      assert.fail(
        `apostrophe inside the single-quoted block (relative line ${line}): `
        + `${text.trim()}\nIt terminates the \`bash -c '...'\` string; reword `
        + 'to avoid it (e.g. "the WebView media gates", not "the WebView’s").',
      );
    }
    const tmp = path.join(fs.mkdtempSync(path.join(os.tmpdir(), 'wf-sh-')), 'block.sh');
    fs.writeFileSync(tmp, block.body);
    try {
      execFileSync('bash', ['-n', tmp], { stdio: 'pipe' });
    } catch (e) {
      assert.fail(`bash -n rejected the block: ${e.stderr?.toString().trim()}`);
    } finally {
      fs.rmSync(path.dirname(tmp), { recursive: true, force: true });
    }
  });
}

// The `[ci-only: ...]` marker exists so a bisection that reads one tier does
// not pay for the other four. Its failure modes are asymmetric: a job that
// wrongly runs costs runner minutes, a job that wrongly skips costs coverage
// silently, and a marker left in a merged commit could silence master
// forever. So the guardrails are gated rather than trusted.
test('every heavy job is gated on the plan job', () => {
  const text = read(WORKFLOW);
  for (const [job, output] of [
    ['validate', 'validate'],
    ['design-web', 'design'],
    ['build-android', 'android'],
    ['build-linux', 'linux'],
    ['build-apple', 'apple'],
    ['screenshots-android', 'screenshots'],
    ['screenshots-ios', 'screenshots'],
    ['screenshots-macos', 'screenshots'],
  ]) {
    const header = text.slice(text.indexOf(`\n  ${job}:\n`));
    const block = header.slice(0, header.indexOf('\n    steps:'));
    assert.match(
      block,
      /\n {4}needs: plan\n/,
      `${job} does not depend on the plan job, so its guard cannot be read`,
    );
    assert.match(
      block,
      new RegExp(`if: needs\\.plan\\.outputs\\.${output} === ?'true'`.replace('===', '==')),
      `${job} is not gated on needs.plan.outputs.${output}`,
    );
  }
});

test('the ci-only marker is honoured on pull requests only', () => {
  const text = read(WORKFLOW);
  const plan = text.slice(text.indexOf('\n  plan:\n'), text.indexOf('\n  validate:\n'));
  assert.match(
    plan,
    /if \[ "\$\{\{ github\.event_name \}\}" = pull_request \]; then/,
    'the plan job reads the marker outside a pull_request guard; a marker ' +
      'that survives a merge would then silence master',
  );
  assert.match(
    plan,
    /ci-only/,
    'the plan job no longer parses a ci-only marker',
  );
  // Comma-delimited matching, so `apple` cannot be enabled by `pineapple`.
  assert.match(
    plan,
    /case ",\$only," in/,
    'token matching is not comma-delimited, so one token can enable another',
  );
});

// PASSKEY-012 runs inside the Android job rather than a job of its own, so no
// plan token guards it and nothing above would notice the step going missing.
test('the Android job runs the passkey gate', () => {
  assert.ok(
    /\n +bash scripts\/run_android_passkey_tests\.sh\n/.test(job(read(WORKFLOW), 'build-android')),
    'build-android no longer runs scripts/run_android_passkey_tests.sh',
  );
});

// A release cannot go green without its store screenshots (docs/releasing.md),
// so which runs make them is decided once, by the plan job, from the event and
// the version line. A step gated on the event by hand would skip the release
// PR and nothing would fail: YAML has no type for "this step makes a
// screenshot".
test('screenshots run on a manual run and on a release PR, decided by plan', () => {
  const text = read(WORKFLOW);
  assert.ok(
    !/\n\s+if: github\.event_name == 'workflow_dispatch'/.test(text),
    "a step is gated on workflow_dispatch by hand; gate it on needs.plan.outputs.screenshots == 'true'",
  );
  const start = text.indexOf('\n  plan:\n');
  const plan = text.slice(start, text.indexOf('\n  validate:\n'));
  assert.match(plan, /\n {6}screenshots: \$\{\{ steps\.screenshots\.outputs\.screenshots \}\}\n/);
  assert.match(plan, /sed -n 's\/\^version: \/\/p' pubspec\.yaml/,
    'the plan job no longer reads the version line, so a release PR would skip the screenshots');
  assert.match(plan, /\*,screenshots,\*\) screenshots=true/,
    'a ci-only marker naming screenshots no longer runs them');
  assert.match(plan,
    /elif \[ "\$\{\{ inputs\.screenshots_only \}\}" = true \]; then\n\s+only=screenshots\n/,
    'the screenshots_only input is no longer the [ci-only: screenshots] marker');
});

// A device's set is a job of its own so a screenshots-only run takes them all
// at once, and the merge job is what makes them one download. A set whose job
// the merge does not wait for is uploaded after the merge ran and is missing
// from it, with every job green.
test('every device feeds the one screenshots artifact', () => {
  const text = read(WORKFLOW);
  const merge = job(text, 'screenshots');
  assert.match(merge, /pattern: '\*-screenshots'/);
  const needs = merge.match(/\n {4}needs: \[([^\]]*)\]/)[1].split(',').map((n) => n.trim());
  for (const id of ['screenshots-android', 'screenshots-ios', 'screenshots-macos']) {
    assert.ok(needs.includes(id), `the screenshots merge does not wait for ${id}`);
    assert.match(job(text, id), /\n +name: [^\n]*-screenshots\n/,
      `${id} uploads no *-screenshots artifact for the merge to take`);
  }
  const ios = job(text, 'screenshots-ios');
  for (const device of ['iphone', 'ipad']) {
    assert.match(ios, new RegExp(`\\n +- device: ${device}\\n`),
      `the iOS screenshot matrix has no ${device}`);
  }
  assert.match(ios, /name: \$\{\{ matrix\.device \}\}-screenshots\n/);
});
