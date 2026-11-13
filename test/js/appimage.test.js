// PLATFORM-013: the AppImage's pieces name what other files own, in shell and
// YAML that cannot import it: the application ID (linux/CMakeLists.txt), the
// variable WebKit reads its moved tree from (linux/wpe_root.patch), and the
// pinned tools. Each mistake here shows only hours into the Snap workflow.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');
const L = require('./helpers/licences');

const nativeId = read('linux/CMakeLists.txt').match(/^ {2}set\(APPLICATION_ID "([\w.]+)"\)$/m)?.[1];

test('PLATFORM-013 check_appimage.sh reads the application ID the build sets', () => {
  const script = 'scripts/check_appimage.sh';
  const expr = read(script).match(/^id="\$\(sed -n '([^']+)' "\$root\/linux\/CMakeLists\.txt"\)"$/m)?.[1];
  assert.ok(expr, `${script}: the sed reading APPLICATION_ID not found`);
  const id = execFileSync('sed', ['-n', expr, 'linux/CMakeLists.txt'], { cwd: REPO, encoding: 'utf8' });
  assert.equal(id.trim(), nativeId);
});

test('PLATFORM-013 AppRun names the moved WebKit by the variable the patch reads', () => {
  const patch = read('linux/wpe_root.patch');
  const added = patch.split('\n').filter((l) => l.startsWith('+') && !l.startsWith('+++'));
  const reads = new Set(added.flatMap((l) => [...l.matchAll(/g_getenv\("(\w+)"\)/g)].map((m) => m[1])));
  assert.deepEqual([...reads], ['WEBSPACE_WPE_ROOT'], 'the patch reads one variable');
  for (const configured of ['PKGLIBEXECDIR', 'PKGLIBDIR', 'PKGDATADIR']) {
    assert.ok(added.some((l) => l.includes(`g_strconcat(root, ${configured}`)),
      `the patch does not move ${configured} under the root`);
  }
  assert.match(read('linux/appimage/AppRun'), /^export WEBSPACE_WPE_ROOT="\$here"$/m);
});

test('PLATFORM-013 every tool that packs the AppImage is a fixed release download, pinned by its SHA-256', () => {
  const rows = L.rows(read('linux/appimage/tools.tsv'));
  assert.deepEqual(rows.map(([name]) => name).sort(),
    ['appimagetool-aarch64.AppImage', 'appimagetool-x86_64.AppImage', 'runtime-aarch64', 'runtime-x86_64']);
  for (const [name, url, sum] of rows) {
    assert.match(url, /^https:\/\/github\.com\/AppImage\/[\w-]+\/releases\/download\/[\w.]+\/[\w.-]+$/, `${name}: ${url}`);
    assert.doesNotMatch(url, /\/(continuous|latest)\//, `${name}: a tag that moves`);
    assert.ok(url.endsWith(`/${name}`), `${name} is fetched under another name`);
    assert.match(sum, /^[0-9a-f]{64}$/, `${name}: no SHA-256`);
  }
});

test('PLATFORM-013 the Snap workflow keeps no AppDir while a bundled package is owed a reading', () => {
  const workflow = read('.github/workflows/snap.yml');
  assert.match(workflow, /node tool\/check_bundle_licences\.js AppDir --owed linux\/appimage\/licences_owed\.tsv/);
  for (const step of ['Keep the AppDir for the release', "Attest the AppDir's provenance", 'Upload the AppDir']) {
    const at = workflow.indexOf(`- name: ${step}`);
    assert.ok(at >= 0, `no step ${step}`);
    assert.match(workflow.slice(at, workflow.indexOf('\n      - name:', at + 1)),
      /if: steps\.appimage-licences\.outputs\.clear == 'true'/, `${step} runs while packages are owed`);
  }
  assert.match(read('scripts/release_appimage.sh'), /grep -qv '\^#' "\$owed"/, 'the release script publishes while packages are owed');
});
