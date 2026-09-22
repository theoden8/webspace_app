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

const repoRoot = path.resolve(__dirname, '..', '..');
const WORKFLOW = path.join('.github', 'workflows', 'build-and-test.yml');

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

const workflowText = fs.readFileSync(path.join(repoRoot, WORKFLOW), 'utf8');
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
  const text = fs.readFileSync(path.join(repoRoot, WORKFLOW), 'utf8');
  for (const [job, output] of [
    ['validate', 'validate'],
    ['design-web', 'design'],
    ['build-android', 'android'],
    ['build-linux', 'linux'],
    ['build-apple', 'apple'],
  ]) {
    const header = text.slice(text.indexOf(`\n  ${job}:\n`));
    const block = header.slice(0, header.indexOf('\n    steps:'));
    assert.match(
      block,
      /\n    needs: plan\n/,
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
  const text = fs.readFileSync(path.join(repoRoot, WORKFLOW), 'utf8');
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
