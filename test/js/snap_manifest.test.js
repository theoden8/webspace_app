// The snap's manifest names things other files own, and snapcraft reads YAML
// that cannot import them: the application ID (APPLICATION_ID in
// linux/CMakeLists.txt), the D-Bus paths the tray exports, and the directories
// WebKit compiles in. This gate holds each to its owner, and keeps the sandbox
// to plugs that say what needs them.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');

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

// scripts/check_snap.sh reads the id with sed, and a pattern that misses it
// fails only in CI's snap job, hours into the build.
test('check_snap.sh reads the application ID this gate reads', () => {
  const script = 'scripts/check_snap.sh';
  const expr = read(script)
    .match(/^id="\$\(sed -n '([^']+)' "\$root\/linux\/CMakeLists\.txt"\)"$/m)?.[1];
  assert.ok(expr, `${script}: the sed reading APPLICATION_ID not found`);
  const id = execFileSync('sed', ['-n', expr, 'linux/CMakeLists.txt'], { cwd: REPO, encoding: 'utf8' });
  assert.equal(id.trim(), nativeId, `${script} reads ${JSON.stringify(id.trim())}, not ${nativeId}`);
});

// The snap's name is the manifest's: the app is keyed by it, so the command a
// user types and `snap run <name>` are the name itself, and the check script
// and the workflow read it from the manifest instead of repeating it.
test('the snap is named once, in its manifest', () => {
  const name = manifest.match(/^name: ([a-z0-9-]+)$/m)?.[1];
  assert.ok(name, `${MANIFEST} has no name:`);
  assert.deepEqual(block('apps').filter((l) => /^ {2}\S/.test(l)), [`  ${name}:`],
    `${MANIFEST}: the app is not keyed by the snap's name, so its command is not ${name}`);
  const restated = new RegExp(`snap (?:run|connections|connect|install)(?: --shell| --dangerous)? \\.?/?${name}\\b|\\b${name}_\\*`);
  for (const file of ['scripts/check_snap.sh', '.github/workflows/snap.yml']) {
    const text = read(file);
    assert.match(text, /sed -n 's\/\^name: /, `${file} does not read the snap's name from ${MANIFEST}`);
    assert.doesNotMatch(text, restated, `${file} names the snap ${name} itself`);
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

// The manifest's platforms are the snap's architectures: CI builds and runs
// each on a runner of its own, and the app part knows where Flutter puts each
// one's bundle.
test('every platform the snap names is built in CI and has a bundle directory', () => {
  const platforms = block('platforms').map((l) => l.match(/^ {2}([a-z0-9]+):$/)?.[1]).filter(Boolean);
  assert.ok(platforms.length > 0, `${MANIFEST} names no platform`);
  const workflow = read('.github/workflows/snap.yml');
  const built = [...workflow.matchAll(/^ {10}- arch: ([a-z0-9]+)$/gm)].map((m) => m[1]);
  assert.deepEqual([...built].sort(), [...platforms].sort(),
    `.github/workflows/snap.yml builds ${built.join(', ')}; ${MANIFEST} names ${platforms.join(', ')}`);
  for (const arch of platforms) {
    assert.match(manifest, new RegExp(`^ {8}${arch}\\) bundle=build/linux/[a-z0-9]+/release/bundle ;;$`, 'm'),
      `${MANIFEST}: the app part has no bundle directory for ${arch}`);
  }
});

// The app runs the tor beside its executable (managed_tor_io.dart's
// _bundleDir), which the app's own build fills (linux/tor.cmake). The snap
// gives that build what tor links and checks what it laid out; a part of its
// own would be a second build of tor beside the one every package shares.
test("the snap's tor is the one the app's build makes (TOR-027)", () => {
  const parts = block('parts').map((l) => l.match(/^ {2}([a-z0-9-]+):$/)?.[1]).filter(Boolean);
  for (const name of ['tor', 'lyrebird']) {
    assert.ok(!parts.includes(name), `${MANIFEST} builds ${name} in a part of its own`);
  }
  assert.doesNotMatch(manifest, /WEBSPACE_TOR_SOURCE=none/,
    `${MANIFEST}: the app part builds without tor`);
  for (const pkg of ['libevent-dev', 'libssl-dev', 'zlib1g-dev']) {
    assert.match(manifest, new RegExp(`^ {6}- ${pkg}$`, 'm'),
      `${MANIFEST}: the app part lacks ${pkg}, which tor's build links`);
  }
  assert.match(manifest, /^ {6}bash scripts\/verify_tor_shipped\.sh "\$bundle"$/m,
    `${MANIFEST}: the app part does not check the tor it built`);
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

// GLib in the snap sends proxy lookups and network-status calls to
// xdg-desktop-portal whenever the desktop plug is connected
// (gportalsupport.c), and the portal answers a snap's only when its
// network-status interface is connected (snap routine portal-info). The gnome
// extension plugs desktop, so without network-status every lookup is refused.
test('the snap plugs network-status, which the portal requires for proxy lookups', () => {
  assert.match(manifest, /^ {4}extensions: \[gnome\]$/m, `${MANIFEST}: the app no longer uses the gnome extension`);
  assert.match(manifest, /^ {6}- network-status$/m, `${MANIFEST} does not plug network-status`);
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

// What WebKit compiles in is decided by its build options, which no type
// reads: libwebrtc trees this table has not read (linux/webkit_third_party.tsv),
// and PDF.js, whose standard fonts are Liberation Sans 1.07.4 under GPL-2.0
// until linux/pdfjs_fonts.sh replaces them, before cmake configures the tree.
function webkitBuildRefusals(text) {
  const out = [];
  for (const option of ['ENABLE_WEB_RTC', 'USE_LIBWEBRTC', 'ENABLE_EXPERIMENTAL_FEATURES']) {
    if (new RegExp(`-D${option}=ON\\b`).test(text)) out.push(`-D${option}=ON`);
  }
  const start = text.indexOf('\n  wpewebkit:\n');
  const part = text.slice(start, text.indexOf('\n\n  ', start + 1));
  if (!/^ {8}-DENABLE_PDFJS=(ON|OFF)$/m.test(part)) out.push('ENABLE_PDFJS is left to its default');
  if (/^ {8}-DENABLE_PDFJS=ON$/m.test(part)) {
    const swap = part.indexOf('bash "$CRAFT_PROJECT_DIR/linux/pdfjs_fonts.sh" --src "$CRAFT_PART_SRC"');
    if (swap < 0 || swap > part.indexOf('cmake -S')) out.push('PDF.js ships its fonts as WebKit has them');
    if (!/^ {6}- fonts-liberation$/m.test(part)) out.push('fonts-liberation is not a build package');
  }
  return out;
}

test('WebKit is built without the parts whose licence it may not ship (LICENSE-001)', () => {
  assert.deepEqual(webkitBuildRefusals(manifest), []);
  const check = read('scripts/check_snap.sh');
  assert.ok(check.includes("grep -a -q 'Liberation Fonts license' \"$webkit\""),
    'scripts/check_snap.sh does not refuse a library carrying Liberation 1.x');
  assert.ok(check.includes("grep -a -q 'Licensed under the SIL Open Font License' \"$webkit\""),
    'scripts/check_snap.sh does not require the OFL fonts in the library');
  const unswapped = manifest.replace(/^ {6}changed="\$\(bash "\$CRAFT_PROJECT_DIR\/linux\/pdfjs_fonts\.sh"[^\n]*\n/m, '');
  assert.deepEqual(webkitBuildRefusals(unswapped), ['PDF.js ships its fonts as WebKit has them'],
    'PDF.js with its own fonts');
  assert.deepEqual(webkitBuildRefusals(manifest.replace(/^ {6}- fonts-liberation\n/m, '')),
    ['fonts-liberation is not a build package'], 'the replacement fonts not installed');
  assert.deepEqual(webkitBuildRefusals(manifest.replace(/^ {8}-DENABLE_PDFJS=ON\n/m, '')),
    ['ENABLE_PDFJS is left to its default'], 'PDF.js on by WebKit\'s default, unseen');
  assert.deepEqual(webkitBuildRefusals(manifest.replace('-DUSE_SYSTEM_UNIFDEF=OFF', '-DUSE_SYSTEM_UNIFDEF=OFF -DENABLE_WEB_RTC=ON')),
    ['-DENABLE_WEB_RTC=ON'], 'WebRTC on');
});

// A part's block of the manifest: from its key to the first blank line.
function partSpan(text, part) {
  const start = text.indexOf(`\n  ${part}:\n`);
  if (start < 0) return null;
  const end = text.indexOf('\n\n  ', start + 1);
  return [start, end < 0 ? text.length : end];
}

// [text] with [from] replaced by [to] in [part]'s block alone.
function inPart(text, part, from, to) {
  const [start, end] = partSpan(text, part);
  return text.slice(0, start) + text.slice(start, end).replace(from, to) + text.slice(end);
}

// The source a part pulls and the commit it checks out: snapcraft's git
// source keys, or an override-pull that fetches one commit.
function checkoutOf(body) {
  const url = body.match(/^ {4}source: (\S+)$/m)?.[1] ?? body.match(/git remote add origin (\S+)/)?.[1];
  const commit = body.match(/^ {4}source-commit: ([0-9a-f]{40})$/m)?.[1]
    ?? body.match(/git fetch .*\borigin ([0-9a-f]{40})$/m)?.[1];
  return { url, commit };
}

// linux/install_notices.sh writes a built library's notices where a staged
// Debian package keeps its own, which the app's licences page reads
// (bundled_notices_io.dart). Both libraries are under the LGPL, so each call
// names the commit it was built from, read off the part's own checkout of it,
// and makes the source offer LGPL asks for (LICENSE-004); libwpe's tree
// carries no LGPL text, so its call gives the build host's. WebKit's call also
// holds its third-party directories to the audited table and says what the
// build changed.
function noticeRefusals(text) {
  const out = [];
  const offered = [
    '--revision "$(git -C "$CRAFT_PART_SRC" rev-parse HEAD)"',
    '--offer',
  ];
  for (const [part, dest, extra] of [
    ['libwpe', 'libwpe', [
      ...offered,
      '--license "BSD-2-clause and LGPL-2+"',
      '--lgpl-text /usr/share/common-licenses/LGPL-2',
    ]],
    ['wpewebkit', 'wpewebkit', [
      ...offered,
      '--third-party "$CRAFT_PROJECT_DIR/linux/webkit_third_party.tsv"',
      '--changed "$changed"',
    ]],
  ]) {
    const span = partSpan(text, part);
    const body = span ? text.slice(...span) : '';
    if (!body.includes('bash "$CRAFT_PROJECT_DIR/linux/install_notices.sh"')) {
      out.push(`${part} writes no notices`);
      continue;
    }
    if (!body.includes(`--dest "$CRAFT_PART_INSTALL/usr/share/doc/${dest}"`)) out.push(`${part}'s notices are not in usr/share/doc/${dest}`);
    for (const flag of extra) if (!body.includes(flag)) out.push(`${part} lacks ${flag}`);
    const { url, commit } = checkoutOf(body);
    if (!commit) out.push(`${part} is not a checkout of one commit, so its HEAD is not the source it offers`);
    const named = body.match(/--source (\S+)/)?.[1];
    if (named !== url) out.push(`${part}'s notices name ${named}, not the ${url} it pulls`);
  }
  if (/^ {6}- -usr\/share\/doc\b/m.test(text)) out.push('a part leaves usr/share/doc out of the snap');
  return out;
}

test('each library the snap builds ships its notices (LICENSE-003)', () => {
  assert.deepEqual(noticeRefusals(manifest), []);
  assert.deepEqual(noticeRefusals(manifest.replace('      - -usr/include\n', '      - -usr/include\n      - -usr/share/doc\n')),
    ['a part leaves usr/share/doc out of the snap'], 'the notices primed out');
});

test("the snap's WebKit is a library a user can replace, its source named and offered (LICENSE-004)", () => {
  assert.deepEqual(noticeRefusals(inPart(manifest, 'wpewebkit', ' --offer \\\n', ' \\\n')), ['wpewebkit lacks --offer'],
    'WebKit without its source offer');
  assert.deepEqual(noticeRefusals(inPart(manifest, 'wpewebkit', /--revision "\$\(git -C [^\n]*\n/, '--revision main \\\n')),
    ['wpewebkit lacks --revision "$(git -C "$CRAFT_PART_SRC" rev-parse HEAD)"'], 'a revision not read off the checkout');
  assert.deepEqual(noticeRefusals(inPart(manifest, 'wpewebkit', ' \\\n        --changed "$changed"\n', '\n')),
    ['wpewebkit lacks --changed "$changed"'], 'a copyright file that hides the fonts it replaced');
  assert.deepEqual(noticeRefusals(inPart(manifest, 'wpewebkit', / origin [0-9a-f]{40}$/m, ' origin main')),
    ['wpewebkit is not a checkout of one commit, so its HEAD is not the source it offers'], 'WebKit fetched at a branch');
  const notices = read('linux/install_notices.sh');
  for (const line of ['echo "Source: $source"', 'Built as it is from $source at $revision.',
    'For at least three years from the day you received this copy']) {
    assert.ok(notices.includes(line), `linux/install_notices.sh no longer writes: ${line}`);
  }
  const check = read('scripts/check_snap.sh');
  assert.ok(check.includes("grep -q '(NEEDED).*\\[libWPEWebKit-2\\.0\\.so'"),
    'scripts/check_snap.sh does not require a library of the app to load WebKit at run time');
  assert.ok(check.includes('$mount/usr/lib/*/libWPEWebKit-2.0.so.*'),
    'scripts/check_snap.sh does not require WebKit as a file of its own');
  assert.match(read('.github/workflows/snap.yml'), /^ +bash scripts\/check_snap\.sh$/m, 'CI does not run scripts/check_snap.sh');
});

// libwpe's src/key-unicode.c, adapted from GDK's gdkkeyuni.c, is under the
// LGPL, and the library ships as libwpe-1.0's own .so, as WebKit's does.
test("the snap's libwpe ships as the LGPL asks: its text, and its source named and offered (LICENSE-004)", () => {
  const libwpe = (from, to) => noticeRefusals(inPart(manifest, 'libwpe', from, to));
  assert.deepEqual(libwpe(' --offer \\\n', ' \\\n'), ['libwpe lacks --offer'], 'libwpe without its source offer');
  assert.deepEqual(libwpe(/--revision "\$\(git -C [^\n]*\n/, '--revision 1.16.3 \\\n'),
    ['libwpe lacks --revision "$(git -C "$CRAFT_PART_SRC" rev-parse HEAD)"'], 'a revision not read off the checkout');
  assert.deepEqual(libwpe('--license "BSD-2-clause and LGPL-2+"', '--license BSD-2-clause'),
    ['libwpe lacks --license "BSD-2-clause and LGPL-2+"'], 'the LGPL of key-unicode.c left unnamed');
  assert.deepEqual(libwpe(' \\\n        --lgpl-text /usr/share/common-licenses/LGPL-2\n', '\n'),
    ['libwpe lacks --lgpl-text /usr/share/common-licenses/LGPL-2'], 'the LGPL named, its text not given');
  assert.deepEqual(libwpe(/^ {4}source: \S+\n {4}source-commit: \S+\n/m, '    source: https://wpewebkit.org/releases/libwpe-1.16.3.tar.xz\n'), [
    'libwpe is not a checkout of one commit, so its HEAD is not the source it offers',
    "libwpe's notices name https://github.com/WebPlatformForEmbedded/libwpe.git, not the https://wpewebkit.org/releases/libwpe-1.16.3.tar.xz it pulls",
  ], 'libwpe from its release tarball, where git would read the project\'s own HEAD');
  const check = read('scripts/check_snap.sh');
  assert.ok(check.includes('$mount/usr/lib/*/libwpe-1.0.so.*'), 'scripts/check_snap.sh does not require libwpe as a file of its own');
  assert.ok(check.includes("grep -q '(NEEDED).*\\[libwpe-1\\.0\\.so'"),
    'scripts/check_snap.sh does not require a library of the snap to load libwpe at run time');
});

test('every third-party tree of WebKit under the GPL is one the build leaves out (LICENSE-001)', () => {
  const rows = read('linux/webkit_third_party.tsv').split('\n')
    .filter((l) => l && !l.startsWith('#')).map((l) => l.split('\t'));
  assert.ok(rows.length > 10, 'linux/webkit_third_party.tsv read no rows');
  const shipped = rows.filter(([, licence, built]) => /(^|[^L])GPL/.test(licence) && built !== 'no')
    .map(([path]) => path);
  assert.deepEqual(shipped, [], 'these trees are under the GPL and marked as compiled in');
  for (const [path, , built, why] of rows) {
    assert.match(built, /^(yes|no)$/, `${path}: built is ${built}`);
    assert.ok(why, `${path} says nothing about why`);
  }
});
