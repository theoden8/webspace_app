// The desktop entry and the metainfo carry the application id, which CMake
// writes into them from APPLICATION_ID in linux/CMakeLists.txt. A template that
// names an id by hand would ship files pointing at another app, and
// configure_file cannot reject that, so this gate holds each id field to its
// placeholder.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

test('the desktop entry takes its icon name from the application id (PLATFORM-008)', () => {
  assert.match(read('linux/webspace.desktop.in'), /^Icon=@APPLICATION_ID@$/m);
});

test('the metainfo takes its ids from the application id (PLATFORM-008)', () => {
  const metainfo = read('linux/webspace.metainfo.xml.in');
  assert.match(metainfo, /<id>@APPLICATION_ID@<\/id>/);
  assert.match(metainfo, /<developer id="@DEVELOPER_ID@">/);
  assert.match(metainfo, /<launchable type="desktop-id">@APPLICATION_ID@\.desktop<\/launchable>/);
});

// AppImageHub runs desktop-file-validate on the entry and appstreamcli on the
// metainfo (PLATFORM-013); the snap and the desktop read them too. Both are
// rendered as CMake renders them, then validated, and each validator must
// refuse a planted mistake. CI installs both; elsewhere the test skips without
// them.
const { execFileSync } = require('node:child_process');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const applicationId = read('linux/CMakeLists.txt').match(/^ {2}set\(APPLICATION_ID "([\w.]+)"\)$/m)?.[1];
const render = (template) => template
  .replaceAll('@APPLICATION_ID@', applicationId)
  .replaceAll('@DEVELOPER_ID@', applicationId.replace(/\.[^.]*$/, ''));

function tool(name) {
  try {
    execFileSync('sh', ['-c', `command -v ${name}`], { stdio: 'ignore' });
    return true;
  } catch (e) {
    if (e.status === undefined) throw e;
    assert.notEqual(process.env.CI, 'true', `${name} is not installed; CI must run this check`);
    return false;
  }
}

// The validator's verdict on [text] written as [file]: null when it passes,
// else what it printed.
function refusal(command, args, { file, text }) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'desktop-files-'));
  try {
    fs.writeFileSync(path.join(dir, file), text);
    execFileSync(command, [...args, path.join(dir, file)], { encoding: 'utf8', stdio: 'pipe' });
    return null;
  } catch (e) {
    if (e.status === undefined) throw e;
    return `${e.stdout}${e.stderr}`;
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

test('the desktop entry passes desktop-file-validate (PLATFORM-013)', (t) => {
  assert.ok(applicationId, 'linux/CMakeLists.txt sets no default APPLICATION_ID');
  if (!tool('desktop-file-validate')) return t.skip('desktop-file-validate is not installed');
  const file = `${applicationId}.desktop`;
  const entry = render(read('linux/webspace.desktop.in'));
  assert.equal(refusal('desktop-file-validate', [], { file, text: entry }), null);
  assert.notEqual(refusal('desktop-file-validate', [], { file, text: entry.replace(/^Type=.*\n/m, '') }), null,
    'an entry with no Type passed');
});

test('the metainfo passes appstreamcli validate (PLATFORM-013)', (t) => {
  if (!tool('appstreamcli')) return t.skip('appstreamcli is not installed');
  const file = `${applicationId}.metainfo.xml`;
  const metainfo = render(read('linux/webspace.metainfo.xml.in'));
  assert.equal(refusal('appstreamcli', ['validate', '--no-net'], { file, text: metainfo }), null);
  assert.notEqual(refusal('appstreamcli', ['validate', '--no-net'], { file, text: metainfo.replace(/<developer id="[^"]*">/, '<developer id="?">') }), null,
    'a metainfo with an invalid developer id passed');
});
