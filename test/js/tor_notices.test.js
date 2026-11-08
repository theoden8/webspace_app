// Execute the build's notice collector with package-manager responses for
// Fedora and Debian, without compiling Tor or changing the host's packages.
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { read } = require('./helpers/source');

const source = read('linux/tor_build.sh');
const collector = source.slice(source.indexOf('notice() {'), source.indexOf('\nqueue=('));

function run(t, { owner = true, files = ['COPYING', 'NOTICE'], missing = false, debian = false } = {}) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'tor-notices-'));
  t.after(() => fs.rmSync(root, { recursive: true, force: true }));
  fs.mkdirSync(path.join(root, 'docs'));
  // Spaces in paths must survive RPM's one-file-per-line output.
  const paths = files.map((name) => path.join(root, `licence files ${name}`));
  paths.forEach((file, i) => {
    if (!missing || i !== paths.length - 1) fs.writeFileSync(file, `Licence text ${i}\n`);
  });
  const result = spawnSync('bash', ['-c', `
set -euo pipefail
out="$1"
dpkg-query() {
  ${debian ? 'printf "bash: %s\\n" "$2"' : 'return 1'}
}
rpm() {
  case "$*" in
    '-qf --qf '* ) ${owner ? 'printf "libevent.x86_64\\n"' : 'return 1'} ;;
    '-q --licensefiles libevent.x86_64') printf '%s' "$RPM_FILES" ;;
    *) echo 'Unexpected RPM arguments' >&2; return 1 ;;
  esac
}
${collector}
notice /usr/lib64/libevent-2.1.so.7.0.1
notice /usr/lib64/libevent-2.1.so.7.0.1
`, 'tor-notices-test', root], {
    encoding: 'utf8', env: { ...process.env, RPM_FILES: paths.join('\n') },
  });
  return { ...result, root };
}

test('Fedora collects every RPM licence file and deduplicates the package notice', (t) => {
  const result = run(t);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(fs.readdirSync(path.join(result.root, 'docs')), ['libevent.x86_64.txt']);
  const notice = fs.readFileSync(path.join(result.root, 'docs/libevent.x86_64.txt'), 'utf8');
  assert.equal((notice.match(/Licence text 0/g) || []).length, 1);
  assert.match(notice, /Licence text 1/);
});

test('Fedora refuses an unowned library or a package with no licence files', (t) => {
  for (const options of [{ owner: false }, { files: [] }]) {
    const result = run(t, options);
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /no package licence files/);
    assert.deepEqual(fs.readdirSync(path.join(result.root, 'docs')), []);
  }
});

test('Fedora refuses missing licence text instead of producing a partial notice', (t) => {
  const result = run(t, { missing: true });
  assert.notEqual(result.status, 0);
  assert.match(result.stderr, /missing RPM licence file/);
  assert.deepEqual(fs.readdirSync(path.join(result.root, 'docs')), []);
});

test('Debian still collects the package copyright and referenced common licences', (t) => {
  const copyright = '/usr/share/doc/bash/copyright';
  if (!fs.existsSync(copyright)) return t.skip('Debian bash copyright is not installed');
  const result = run(t, { debian: true });
  assert.equal(result.status, 0, result.stderr);
  const notice = fs.readFileSync(path.join(result.root, 'docs/bash.txt'), 'utf8');
  assert.ok(notice.includes(fs.readFileSync(copyright, 'utf8')));
  const references = fs.readFileSync(copyright, 'utf8').match(/\/usr\/share\/common-licenses\/[A-Za-z0-9.+-]+/g) || [];
  for (const reference of references) {
    const file = reference.replace(/\.$/, '');
    if (fs.existsSync(file)) assert.ok(notice.includes(fs.readFileSync(file, 'utf8')));
  }
});
