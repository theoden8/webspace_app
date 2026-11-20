// DL-001: the file chooser's camera capture hands the camera app a content URI
// from FileProvider.getUriForFile, under the authority the fork builds from
// the package name. A provider missing from the merged manifest, under another
// authority, or with no path covering the captured file makes that call throw,
// and the fork logs it and opens the chooser with no camera option. Nothing in
// Dart sees the manifest, so this reads it (rung 5: no type spans XML and Java).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { read } = require('./helpers/source');

const MANIFEST = 'android/app/src/main/AndroidManifest.xml';
const EXTENSION = 'flutter_inappwebview_android.fileprovider';

const attr = (tag, name) => tag.match(new RegExp(`android:${name}="([^"]*)"`))?.[1];

function provider() {
  const src = read(MANIFEST).replace(/<!--[\s\S]*?-->/g, '');
  const found = [...src.matchAll(/<provider\b[\s\S]*?<\/provider>/g)]
    .map((m) => m[0])
    .filter((p) => attr(p, 'authorities')?.endsWith(`.${EXTENSION}`));
  assert.equal(found.length, 1, `${MANIFEST} declares one provider for ${EXTENSION}`);
  return found[0];
}

test('the manifest declares the file chooser FileProvider (DL-001)', () => {
  const p = provider();
  const open = p.slice(0, p.indexOf('>') + 1);
  assert.equal(attr(open, 'name'), 'androidx.core.content.FileProvider');
  // The runtime package name is the applicationId, flavor and debug suffix included.
  assert.equal(attr(open, 'authorities'), `\${applicationId}.${EXTENSION}`);
  assert.equal(attr(open, 'exported'), 'false', 'a FileProvider is never exported');
  assert.equal(attr(open, 'grantUriPermissions'), 'true',
    'the camera app reads the URI only through a grant');
  const meta = p.match(/<meta-data\b[^>]*>/g) ?? [];
  const paths = meta.find((m) => attr(m, 'name') === 'android.support.FILE_PROVIDER_PATHS');
  assert.ok(paths, 'the provider names its FILE_PROVIDER_PATHS resource');
  assert.match(attr(paths, 'resource') ?? '', /^@xml\/\w+$/);
});

test('its paths cover files, cache and their external equivalents (DL-001)', () => {
  const resource = attr(
    provider().match(/<meta-data\b[^>]*FILE_PROVIDER_PATHS[^>]*>/)[0], 'resource');
  const xml = read(`android/app/src/main/res/xml/${resource.slice('@xml/'.length)}.xml`)
    .replace(/<!--[\s\S]*?-->/g, '');
  const roots = new Map(
    [...xml.matchAll(/<([a-z-]+-path)\b([^>]*)\/>/g)].map((m) => [m[1], m[2].match(/path="([^"]*)"/)?.[1]]));
  // getCapturedFile writes to getExternalFilesDir(null), external-files-path's root.
  for (const root of ['files-path', 'cache-path', 'external-files-path', 'external-cache-path']) {
    assert.equal(roots.get(root), '.', `${resource} shares the whole of ${root}`);
  }
});

// The authority is the package name plus the fork's constant: read it from the
// pinned checkout, so a fork that renames it fails here, not on a device.
test('the authority matches the pinned fork (DL-001)', (t) => {
  const ref = read('pubspec.lock')
    .match(/flutter_inappwebview_android:[\s\S]*?resolved-ref: "([0-9a-f]+)"/)?.[1];
  assert.ok(ref, 'pubspec.lock pins flutter_inappwebview_android to a git ref');
  const java = path.join(
    process.env.PUB_CACHE ?? path.join(os.homedir(), '.pub-cache'),
    'git', `flutter_inappwebview-${ref}`, 'flutter_inappwebview_android/android/src/main/java',
    'com/pichillilorenzo/flutter_inappwebview_android/InAppWebViewFileProvider.java');
  if (!fs.existsSync(java)) {
    assert.notEqual(process.env.CI, 'true', `${java} is missing; run pub get first`);
    t.skip('the fork is not checked out; run fvm flutter pub get');
    return;
  }
  const constant = fs.readFileSync(java, 'utf8')
    .match(/fileProviderAuthorityExtension\s*=\s*"([^"]+)"/)?.[1];
  assert.equal(constant, EXTENSION);
});
