// The flatpak manifest repeats values other files own, and flatpak-builder
// reads YAML that cannot import them. So this gate holds each copy to its
// owner: the Flutter version (.fvmrc), the uBO commit build.rs embeds
// (UBO_COMMIT), and the app ID (APPLICATION_ID in linux/CMakeLists.txt),
// which also names the desktop entry and metainfo the manifest installs.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, exists } = require('./helpers/source');

const MANIFEST = 'linux/flatpak/flatpak-flutter.yml';
const manifest = read(MANIFEST);

// The `key:` of the source list item whose `url:` is `url`; the item ends at
// the next `- ` entry.
function sourceRef(url, key) {
  const lines = manifest.split('\n');
  const at = lines.findIndex((l) => l.trim() === `url: ${url}`);
  assert.ok(at >= 0, `${MANIFEST} has no source ${url}`);
  for (let i = at + 1; i < lines.length && !lines[i].trim().startsWith('- '); i++) {
    const m = lines[i].match(new RegExp(`^\\s*${key}:\\s*(\\S+)\\s*$`));
    if (m) return m[1];
  }
  assert.fail(`${MANIFEST}: source ${url} has no ${key}: after its url:`);
}

const appId = manifest.match(/^id:\s*(\S+)\s*$/m)?.[1];

test('the manifest builds the Flutter version .fvmrc pins', () => {
  assert.equal(
    sourceRef('https://github.com/flutter/flutter.git', 'tag'),
    JSON.parse(read('.fvmrc')).flutter,
  );
});

test('the manifest checks out the uBO commit build.rs embeds', () => {
  const embedded = read('rust/webspace_adblock/build.rs')
    .match(/^const UBO_COMMIT: &str = "([0-9a-f]{40})";$/m)?.[1];
  assert.ok(embedded, 'UBO_COMMIT not found in build.rs');
  assert.equal(sourceRef('https://github.com/gorhill/uBlock.git', 'commit'), embedded);
});

test('the manifest id is the Linux application id', () => {
  const cmake = read('linux/CMakeLists.txt')
    .match(/^set\(APPLICATION_ID "([^"]+)"\)$/m)?.[1];
  assert.ok(appId, `${MANIFEST} has no id:`);
  assert.equal(appId, cmake);
});

test('the desktop entry and metainfo are named by the app id', () => {
  assert.ok(exists(`linux/${appId}.desktop`), `linux/${appId}.desktop is missing`);
  const metainfo = read(`linux/${appId}.metainfo.xml`);
  assert.match(metainfo, new RegExp(`<id>${appId.replaceAll('.', '\\.')}</id>`));
  assert.match(metainfo, new RegExp(`<launchable type="desktop-id">${appId.replaceAll('.', '\\.')}\\.desktop</launchable>`));
});
