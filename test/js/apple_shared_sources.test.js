// One copy of each Apple plugin both Runners need, and one App Group id.
//
// The macOS Runner kept its own copy of the shortcuts plugin and the App
// Intents, differing from iOS's in the App Group id and an availability
// attribute; the id itself was written into eight files across both Runners
// and both share extensions, each with an "update both" comment. These files
// now live once under ios/Runner and the macOS project compiles them from
// there, as it already did TorControllerPlugin.swift (whose own gate is in
// tor_bootstrap_observability.test.js). This keeps it that way.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, exists, files, code } = require('./helpers/source');

const SHARED = ['AppGroup', 'ShareIntentPlugin', 'ShortcutsPlugin', 'WebSpaceAppIntents'];
const PROJECTS = {
  ios: { pbx: 'ios/Runner.xcodeproj/project.pbxproj', path: (n) => `path = ${n}.swift; sourceTree = "<group>"` },
  macos: { pbx: 'macos/Runner.xcodeproj/project.pbxproj', path: (n) => `path = ../ios/Runner/${n}.swift; sourceTree = SOURCE_ROOT` },
};

/** File names a native target's Sources phase compiles. */
function compiledBy(pbx, target) {
  const block = pbx.match(new RegExp(
    `/\\* ${target} \\*/ = \\{\\s*isa = PBXNativeTarget;[\\s\\S]*?buildPhases = \\(([\\s\\S]*?)\\);`));
  assert.ok(block, `no native target ${target}`);
  const phase = block[1].match(/(\w{24}) \/\* Sources \*\//);
  assert.ok(phase, `${target} has no Sources phase`);
  const files = pbx.match(new RegExp(`${phase[1]} /\\* Sources \\*/ = \\{[\\s\\S]*?files = \\(([\\s\\S]*?)\\);`));
  return [...files[1].matchAll(/\/\* (\S+) in Sources \*\//g)].map((m) => m[1]);
}

test('each shared source exists once, under ios/Runner', () => {
  for (const name of SHARED) {
    assert.ok(exists(`ios/Runner/${name}.swift`), `ios/Runner/${name}.swift is missing`);
    assert.ok(!exists(`macos/Runner/${name}.swift`),
      `macos/Runner/${name}.swift is a second copy, which will drift`);
  }
});

test('both Runners compile every shared source', () => {
  for (const [platform, { pbx: rel, path }] of Object.entries(PROJECTS)) {
    const pbx = read(rel);
    const compiled = compiledBy(pbx, 'Runner');
    for (const name of SHARED) {
      assert.ok(pbx.includes(path(name)), `${rel} must reference the ${platform} path of ${name}.swift`);
      assert.ok(compiled.includes(`${name}.swift`), `${rel}: the Runner target does not compile ${name}.swift`);
    }
  }
});

test('both share extensions compile the App Group, and nothing Flutter', () => {
  for (const { pbx: rel } of Object.values(PROJECTS)) {
    const compiled = compiledBy(read(rel), 'ShareExtension');
    assert.ok(compiled.includes('AppGroup.swift'), `${rel}: the ShareExtension does not compile AppGroup.swift`);
    for (const name of SHARED.filter((n) => n !== 'AppGroup')) {
      assert.ok(!compiled.includes(`${name}.swift`), `${rel}: the ShareExtension compiles ${name}.swift`);
    }
  }
  assert.doesNotMatch(read('ios/Runner/AppGroup.swift'), /^\s*import\s+(?!Foundation\b)/m,
    'AppGroup.swift is compiled into the extensions, so it imports Foundation only');
});

test('the shared plugins pick their Flutter module per platform', () => {
  for (const name of SHARED) {
    const src = code(read(`ios/Runner/${name}.swift`));
    if (!/import Flutter/.test(src)) continue;
    assert.match(src, /#if canImport\(FlutterMacOS\)\s*\n\s*(?:import Cocoa\s*\n\s*)?import FlutterMacOS/,
      `ios/Runner/${name}.swift must import FlutterMacOS when it is there and Flutter otherwise`);
  }
});

test('the App Group id is written in AppGroup.swift alone', () => {
  const swift = [...files('ios', /\.swift$/), ...files('macos', /\.swift$/)]
    .filter((f) => f !== 'ios/Runner/AppGroup.swift' && !f.includes('/Pods/'));
  const hits = swift.filter((f) => read(f).includes('group.org.codeberg.theoden8.webspace'));
  assert.deepEqual(hits, [], 'read AppGroup.id instead');
});

test('the type-check covers every shared source', () => {
  const check = read('tool/swift_typecheck/check.sh');
  for (const name of SHARED) {
    assert.match(check, new RegExp(`\\b${name}\\b`), `tool/swift_typecheck/check.sh must type-check ${name}.swift`);
  }
});
