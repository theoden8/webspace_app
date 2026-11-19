// The webview's file chooser hands the camera a content URI from the app's
// FileProvider, which Android finds by authority (DL-001).
//
// A source gate (rung 5): the provider is manifest and resource XML, which
// no Dart tier reads and no tier here runs an activity to resolve. The
// authority is held to the one flutter_inappwebview_android looks up, read
// from the plugin's own source, so the two cannot drift.

const fs = require('node:fs');
const path = require('node:path');
const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');
const L = require('./helpers/licences');

const manifest = read('android/app/src/main/AndroidManifest.xml');
const providers = [...manifest.matchAll(/<provider\b[\s\S]*?<\/provider>/g)].map((m) => m[0]);
const chooser = providers.find((p) => /android:name="androidx\.core\.content\.FileProvider"/.test(p));

test('DL-001: the manifest declares the FileProvider, private and granting', () => {
  assert.ok(chooser, 'AndroidManifest.xml declares androidx.core.content.FileProvider');
  assert.match(chooser,
    /android:authorities="\$\{applicationId\}\.flutter_inappwebview_android\.fileprovider"/);
  assert.match(chooser, /android:exported="false"/);
  assert.match(chooser, /android:grantUriPermissions="true"/);
});

test('DL-001: its paths cover files and cache, internal and external', () => {
  const [, res] = chooser.match(
    /android:name="android\.support\.FILE_PROVIDER_PATHS"\s+android:resource="@xml\/([\w]+)"/) ?? [];
  assert.ok(res, 'the provider names its FILE_PROVIDER_PATHS resource');
  const paths = read(`android/app/src/main/res/xml/${res}.xml`);
  for (const tag of ['files-path', 'cache-path', 'external-path', 'external-files-path', 'external-cache-path']) {
    assert.match(paths, new RegExp(`<${tag}\\b[^>]*path="\\."`), `${res}.xml covers <${tag}>`);
  }
});

const packages = L.pubPackages();

test('DL-001: the authority is the one the plugin asks FileProvider for',
  { skip: packages ? false : 'run `flutter pub get` first' }, () => {
    const plugin = packages.get('flutter_inappwebview_android');
    assert.ok(plugin, 'flutter_inappwebview_android is a dependency');
    const source = fs.readFileSync(path.join(plugin.dir,
      'android/src/main/java/com/pichillilorenzo/flutter_inappwebview_android/InAppWebViewFileProvider.java'), 'utf8');
    const [, extension] = source.match(/fileProviderAuthorityExtension\s*=\s*"([^"]+)"/) ?? [];
    assert.equal(extension, 'flutter_inappwebview_android.fileprovider',
      'the plugin appends this to the package name');
    assert.ok(chooser.includes(`android:authorities="\${applicationId}.${extension}"`));
  });
