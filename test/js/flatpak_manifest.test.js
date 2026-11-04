// The flatpak manifest repeats values other files own, and flatpak-builder
// reads YAML that cannot import them. So this gate holds each copy to its
// owner: the Flutter version (.fvmrc), the Rust toolchain
// (rust-toolchain.toml), the tor source release linux/tor.cmake pins, and the
// app ID, which
// reaches APPLICATION_ID in linux/CMakeLists.txt through
// WEBSPACE_APPLICATION_ID. The manifest builds as committed, so a packaging
// repository that runs flatpak-flutter on it gets every one of them.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

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

test('the manifest builds with the Rust toolchain rust-toolchain.toml pins', () => {
  const channel = read('rust-toolchain.toml').match(/^channel\s*=\s*"([^"]+)"\s*$/m)?.[1];
  assert.ok(channel, 'channel not found in rust-toolchain.toml');
  // flatpak-flutter takes the version from this module's name.
  assert.deepEqual([...manifest.matchAll(/^\s*- generated\/modules\/rustup-(\S+)\.json\s*$/gm)].map((m) => m[1]),
    [channel], `${MANIFEST} does not name the one rustup module rust-toolchain.toml pins`);
  assert.deepEqual([...manifest.matchAll(/^\s*RUSTUP_TOOLCHAIN:\s*(\S+)\s*$/gm)].map((m) => m[1]),
    [channel], `${MANIFEST} does not set RUSTUP_TOOLCHAIN to rust-toolchain.toml's channel`);
});

// flatpak-builder gives the build no network, so tor.cmake's download fails
// there: the manifest fetches the source release and names it.
test('the manifest gives the build the tor source release tor.cmake pins (TOR-027)', () => {
  const cmake = read('linux/tor.cmake');
  const version = cmake.match(/^set\(TOR_VERSION "([^"]+)"\)$/m)?.[1];
  const sha256 = cmake.match(/^set\(TOR_SOURCE_SHA256\s+"([0-9a-f]{64})"\)$/m)?.[1];
  assert.ok(version && sha256, 'linux/tor.cmake pins no version and SHA-256');
  const tarball = `tor-${version}.tar.gz`;
  const url = `https://archive.torproject.org/tor-package-archive/${tarball}`;
  assert.equal(sourceRef(url, 'sha256'), sha256, `${MANIFEST}: ${tarball} is not at the pinned SHA-256`);
  assert.equal(sourceRef(url, 'dest'), 'flatpak-sources');
  const named = [...manifest.matchAll(/^\s*WEBSPACE_TOR_SOURCE: (\S+)$/gm)].map((m) => m[1]);
  assert.deepEqual(named, [`/run/build/${appId.split('.').pop()}/flatpak-sources/${tarball}`],
    `${MANIFEST} does not name the tarball in WEBSPACE_TOR_SOURCE once, for every arch`);
  assert.match(manifest, /^ {6}- bash scripts\/verify_tor_shipped\.sh "\$BUNDLE"$/m,
    `${MANIFEST} does not check the tor it bundles on every arch`);
});

// The binary's GApplication id names its Wayland window and its desktop files,
// so it has to be the flatpak's id, not the native build's.
test('the flatpak builds the app under the manifest id, the native build under its own (PLATFORM-009)', () => {
  assert.equal(appId, 'page.codeberg.theoden8.webspace_app');
  assert.match(manifest, /^ {6}- WEBSPACE_APPLICATION_ID="\$FLATPAK_ID" flutter build linux /m,
    `${MANIFEST} does not pass its id to flutter build linux`);
  const cmake = read('linux/CMakeLists.txt');
  assert.match(cmake, /^ {2}set\(APPLICATION_ID "\$ENV\{WEBSPACE_APPLICATION_ID\}"\)$/m,
    'linux/CMakeLists.txt does not take APPLICATION_ID from WEBSPACE_APPLICATION_ID');
  assert.match(cmake, /^ {2}set\(APPLICATION_ID "org\.codeberg\.theoden8\.webspace"\)$/m,
    'linux/CMakeLists.txt does not fall back to the id earlier releases ran under');
});

// flatpak-flutter and scripts/build_flatpak.sh find the app module by the last
// part of the id, and flatpak-builder builds it in /run/build/<module>.
test('the app module is named after the id, and its build paths follow', () => {
  const module = appId.split('.').pop();
  assert.match(manifest, new RegExp(`^  - name: ${module}$`, 'm'),
    `${MANIFEST} has no module named ${module}, the last part of its id`);
  for (const [, dir] of manifest.matchAll(/\/run\/build\/([^/\s]+)\//g)) {
    assert.equal(dir, module,
      `${MANIFEST} builds under /run/build/${dir}, not the app module's /run/build/${module}`);
  }
});

// The finish-args block: each entry with the line above it.
function finishArgs() {
  const lines = manifest.split('\n');
  const start = lines.indexOf('finish-args:');
  assert.ok(start >= 0, `${MANIFEST} has no finish-args:`);
  const entries = [];
  for (let i = start + 1; i < lines.length && /^\s|^$/.test(lines[i]); i++) {
    const m = lines[i].match(/^ {2}- '?(--[^']*?)'?\s*$/);
    if (m) entries.push({ arg: m[1], above: lines[i - 1] });
  }
  return entries;
}

// The sandbox's D-Bus proxy answers a call to a name the manifest does not
// grant with ServiceUnknown, the error a desktop with no tray gives, so the
// icon never shows and nothing fails.
test('the flatpak may call the tray watcher the app registers with (NOTIF-019)', () => {
  const watcher = read('lib/services/status_notifier_tray.dart')
    .match(/^const _watcher = '([\w.]+)';$/m)?.[1];
  assert.ok(watcher, '_watcher not found in lib/services/status_notifier_tray.dart');
  assert.ok(finishArgs().some((e) => e.arg === `--talk-name=${watcher}`),
    `${MANIFEST} lets the app call ${watcher} nowhere in finish-args`);
});

test('each sandbox permission names what needs it, and none is the whole bus or home', () => {
  const entries = finishArgs();
  assert.ok(entries.length > 0, `${MANIFEST}: no finish-args entries read`);
  for (const { arg, above } of entries) {
    assert.match(above, /^ {2}# \S/, `${MANIFEST}: ${arg} has no comment line above it`);
    assert.doesNotMatch(arg, /^--socket=session-bus$|^--socket=system-bus$|^--filesystem=(home|host)(\b|$)/,
      `${MANIFEST} grants ${arg}`);
  }
});
