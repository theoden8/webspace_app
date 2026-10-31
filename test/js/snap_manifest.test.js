// The snap's manifest names things other files own, and snapcraft reads YAML
// that cannot import them: the application ID (APPLICATION_ID in
// linux/CMakeLists.txt), the D-Bus paths the tray exports, and the directories
// WebKit compiles in. This gate holds each to its owner, and keeps the sandbox
// to plugs that say what needs them.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const MANIFEST = 'snap/snapcraft.yaml';
const manifest = read(MANIFEST);
const lines = manifest.split('\n');

// The lines of the top-level block `key:`, up to the next top-level key.
function block(key) {
  const start = lines.indexOf(`${key}:`);
  assert.ok(start >= 0, `${MANIFEST} has no top-level ${key}:`);
  const end = lines.findIndex((l, i) => i > start && /^[a-z]/.test(l));
  return lines.slice(start + 1, end < 0 ? lines.length : end);
}

const nativeId = read('linux/CMakeLists.txt')
  .match(/^ {2}set\(APPLICATION_ID "([\w.]+)"\)$/m)?.[1];

test('the snap runs the app under the native application ID (PLATFORM-009)', () => {
  assert.ok(nativeId, 'the default APPLICATION_ID not found in linux/CMakeLists.txt');
  assert.doesNotMatch(manifest, /WEBSPACE_APPLICATION_ID/,
    `${MANIFEST} builds under another id; the snap keeps the one every native build runs as`);
  const named = [...manifest.matchAll(/\borg\.codeberg\.[\w.]+?(?=\.desktop|\.metainfo|\.png|\s|$)/gm)]
    .map((m) => m[0]);
  assert.ok(named.length >= 5, `${MANIFEST}: the id is named in fewer places than read`);
  for (const id of named) assert.equal(id, nativeId, `${MANIFEST} names ${id}, not ${nativeId}`);
  for (const [key, path] of [
    ['common-id', nativeId],
    ['desktop', `usr/share/applications/${nativeId}.desktop`],
  ]) {
    assert.match(manifest, new RegExp(`^ {4}${key}: ${path.replaceAll('.', '\\.')}$`, 'm'),
      `${MANIFEST}: the app's ${key} is not ${path}`);
  }
});

// GApplication owns the application ID on the session bus, and strict
// confinement lets a snap own a name only through a dbus slot.
test('the snap owns its application ID on the session bus (PLATFORM-011)', () => {
  const slots = block('slots').join('\n');
  assert.match(slots, /^ {4}interface: dbus\n {4}bus: session\n {4}name: (\S+)$/m,
    `${MANIFEST} has no session-bus dbus slot`);
  assert.equal(slots.match(/^ {4}name: (\S+)$/m)[1], nativeId);
});

// A release build of WebKit runs its helper processes only from the directory
// it was configured with, so the snap builds WPE for /usr and binds each
// directory it compiles in to the snap's copy.
test("WebKit's compiled-in directories are bound to the snap's copies (PLATFORM-012)", () => {
  assert.match(manifest, /^ {8}-DCMAKE_INSTALL_PREFIX=\/usr \\$/m,
    `${MANIFEST} does not build WPE for /usr, the prefix the layout binds`);
  const binds = Object.fromEntries([...block('layout').join('\n')
    .matchAll(/^ {2}(\/usr\/\S+):\n {4}bind: (\S+)$/gm)].map((m) => [m[1], m[2]]));
  for (const dir of [
    '/usr/libexec/wpe-webkit-2.0',
    '/usr/lib/$CRAFT_ARCH_TRIPLET_BUILD_FOR/wpe-webkit-2.0',
    '/usr/share/wpe-webkit-2.0',
  ]) {
    assert.equal(binds[dir], `$SNAP${dir}`, `${MANIFEST} does not bind ${dir} to $SNAP${dir}`);
  }
});

// unity7 is the plug that lets a snap register a StatusNotifierItem, and its
// AppArmor rules allow the item and its dbusmenu at fixed object paths only;
// an item exported elsewhere is denied and the icon never shows.
test('the tray exports its item and menu where unity7 lets a snap (NOTIF-019)', () => {
  const tray = read('lib/services/status_notifier_tray.dart');
  assert.equal(tray.match(/^final _itemPath = DBusObjectPath\('([^']+)'\);$/m)?.[1], '/StatusNotifierItem');
  assert.equal(tray.match(/^final _menuPath = DBusObjectPath\('([^']+)'\);$/m)?.[1], '/MenuBar');
  assert.match(manifest, /^ {6}- unity7$/m, `${MANIFEST} does not plug unity7`);
});

test('each plug names what needs it, and none is the home directory or the host (PLATFORM-012)', () => {
  const start = lines.indexOf('    plugs:');
  assert.ok(start >= 0, `${MANIFEST}: the app has no plugs:`);
  let read = 0;
  for (let i = start + 1; i < lines.length && /^ {6}(-|#)/.test(lines[i]); i++) {
    const plug = lines[i].match(/^ {6}- (\S+)$/)?.[1];
    if (!plug) continue;
    read++;
    assert.match(lines[i - 1], /^ {6}# \S/, `${MANIFEST}: the ${plug} plug has no comment line above it`);
    assert.doesNotMatch(plug, /^(home|personal-files|system-files|removable-media|system-observe)$/,
      `${MANIFEST} plugs ${plug}`);
  }
  assert.ok(read > 0, `${MANIFEST}: no plugs read`);
});

// The build reads the Flutter and Rust versions from the files that pin them
// for every other build; a copy here would go stale without failing.
test('the snap restates no version .fvmrc or rust-toolchain.toml pins', () => {
  const flutter = JSON.parse(read('.fvmrc')).flutter;
  const rust = read('rust-toolchain.toml').match(/^channel\s*=\s*"([^"]+)"\s*$/m)?.[1];
  assert.ok(rust, 'channel not found in rust-toolchain.toml');
  for (const version of [flutter, rust]) {
    assert.ok(!manifest.includes(version), `${MANIFEST} restates ${version}`);
  }
  assert.match(manifest, /\.fvmrc\)"$/m, `${MANIFEST} does not read the Flutter version from .fvmrc`);
  assert.match(manifest, /rust-toolchain\.toml\)"$/m, `${MANIFEST} does not read the Rust channel from rust-toolchain.toml`);
});
