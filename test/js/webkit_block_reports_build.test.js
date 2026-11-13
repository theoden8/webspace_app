// Structural gate: an App Store build carries none of WebKit's block reports,
// which name a WebKit method Apple does not publish, and only the `direct`
// flavor does (CB-023).
//
// The Swift sits wholly inside `#if WEBSPACE_DIRECT`, a condition the Runner
// target sets in its -direct configurations alone, and
// scripts/check_webkit_block_reports.sh tells a built app with the code from
// one without it by the method's name. No type spans the Swift, the Xcode
// projects, the workflow and the signing script, or says that the script's
// marker is still the selector the Swift adds, so this gate holds them to each
// other (rung 5).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { read, files } = require('./helpers/source');

const SCRIPT = 'scripts/check_webkit_block_reports.sh';
const SWIFT = 'ios/Runner/WebKitBlockReports.swift';
const PLUGIN = 'ios/Runner/ContentRuleListPlugin.swift';
const WORKFLOW = '.github/workflows/build-and-test.yml';
const CONDITION = 'WEBSPACE_DIRECT';

const marker = (() => {
  const m = read(SCRIPT).match(/^marker='([^']+)'$/m);
  assert.ok(m, `${SCRIPT} names its marker as marker='...'`);
  return m[1];
})();

const code = (src) => src.split('\n').filter((l) => !/^\s*(\/\/|$)/.test(l));

test('the marker is the selector the Swift adds', () => {
  assert.ok(read(SWIFT).includes(`"${marker}"`),
    `${SWIFT} no longer adds ${marker}: update the marker in ${SCRIPT}`);
});

test(`the Swift is all inside #if ${CONDITION}`, () => {
  const lines = code(read(SWIFT));
  assert.equal(lines[0].trim(), `#if ${CONDITION}`);
  assert.equal(lines[lines.length - 1].trim(), '#endif');
});

test('no other Runner source names the selector', () => {
  const found = [];
  for (const dir of ['ios/Runner', 'macos/Runner']) {
    for (const file of files(dir, /\.swift$/)) {
      if (file === SWIFT) continue;
      if (read(file).includes(marker)) found.push(file);
    }
  }
  assert.deepEqual(found, []);
});

test(`the plugin reaches the reports only under #if ${CONDITION}`, () => {
  const src = read(PLUGIN);
  const uses = [...src.matchAll(/WebKitBlockReports\./g)].map((m) => m.index);
  assert.ok(uses.length > 0, `${PLUGIN} no longer reaches WebKitBlockReports`);
  for (const at of uses) {
    const before = src.slice(0, at);
    const opened = before.lastIndexOf(`#if ${CONDITION}`);
    const closed = Math.max(before.lastIndexOf('#else'), before.lastIndexOf('#endif'));
    assert.ok(opened > closed, `${PLUGIN} reaches WebKitBlockReports outside #if ${CONDITION}`);
  }
});

for (const platform of ['ios', 'macos']) {
  test(`${platform}: ${CONDITION} is set in the Runner target's -direct configurations alone`, () => {
    const project = read(`${platform}/Runner.xcodeproj/project.pbxproj`);
    const list = project.match(
      /Build configuration list for PBXNativeTarget "Runner" \*\/ = \{[\s\S]*?buildConfigurations = \(([\s\S]*?)\);/);
    assert.ok(list, `no Runner target configuration list in ${platform}`);
    const runner = new Map([...list[1].matchAll(/(\w{24}) \/\* ([\w-]+) \*\//g)].map((m) => [m[1], m[2]]));
    const setIn = [];
    for (const m of project.matchAll(/\t\t(\w{24}) \/\* ([\w-]+) \*\/ = \{\n\t\t\tisa = XCBuildConfiguration;[\s\S]*?\n\t\t\};/g)) {
      if (m[0].includes(CONDITION)) setIn.push(`${runner.has(m[1]) ? 'Runner' : 'other'} ${m[2]}`);
    }
    assert.deepEqual(setIn.sort(),
      ['Runner Debug-direct', 'Runner Profile-direct', 'Runner Release-direct']);
    assert.ok(project.includes('WebKitBlockReports.swift in Sources'),
      `${platform}'s Runner target does not compile ${SWIFT}`);
  });
}

test('CI checks a flavorless build lacks the reports and its direct builds carry them', () => {
  const workflow = read(WORKFLOW);
  const checked = (want, app) => new RegExp(
    `check_webkit_block_reports\\.sh ${want} \\\\\\s*\\S*${app.replace(/\./g, '\\.')}\\n`);
  assert.match(workflow, checked('absent', 'Products/Release/webspace.app'),
    'no absent check of the flavorless macOS build');
  assert.match(workflow, checked('present', 'Applications/Runner.app'),
    'no present check of the iOS IPA');
  assert.match(workflow, checked('present', 'Products/Release-direct/webspace.app'),
    'no present check of the macOS direct build');
});

test('signing for the Mac App Store refuses a build that carries them', () => {
  assert.match(read('scripts/sign_macos.sh'),
    /"\$REPO_ROOT\/scripts\/check_webkit_block_reports\.sh" absent "\$APP"/);
});

test(`the Linux type-check reads the Swift with ${CONDITION} too`, () => {
  const check = read('tool/swift_typecheck/check.sh');
  assert.ok(check.includes('WebKitBlockReports'), 'tool/swift_typecheck skips the Swift');
  assert.ok(check.includes(`-D ${CONDITION}`), `tool/swift_typecheck never defines ${CONDITION}`);
});

test('tool/swift_tests runs the files the Xcode projects compile, and CI runs it', () => {
  const linked = [];
  for (const dir of ['tool/swift_tests/Sources/Runner', 'tool/swift_tests/Tests/RunnerTests']) {
    for (const name of fs.readdirSync(dir)) {
      const file = path.join(dir, name);
      assert.ok(fs.lstatSync(file).isSymbolicLink(),
        `${file} is a copy: link it to the Runner file Xcode compiles`);
      assert.ok(fs.existsSync(file), `${file} links to nothing`);
      linked.push(path.relative('.', fs.realpathSync(file)));
    }
  }
  assert.deepEqual(linked.sort(), [
    'ios/Runner/TorControllerPlugin.swift',
    'ios/Runner/WebKitBlockedLoads.swift',
    'ios/RunnerTests/TorControlParsingTests.swift',
    'ios/RunnerTests/WebKitBlockedLoadsTests.swift',
  ]);
  for (const platform of ['ios', 'macos']) {
    assert.ok(read(`${platform}/Runner.xcodeproj/project.pbxproj`).includes('WebKitBlockedLoads.swift in Sources'),
      `${platform}'s Runner does not compile the load counting`);
  }
  assert.match(read(WORKFLOW), /run: \.\/tool\/swift_tests\/run\.sh\n/);
});
