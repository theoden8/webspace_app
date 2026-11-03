// Structural gate: an App Store build carries none of the search of
// addons.mozilla.org, and only the `direct` flavor does (WEBEXT-019).
//
// The flavor is the one switch: `appFlavor` is the Xcode scheme a build was
// made with, and scripts/check_extension_search.sh tells a built snapshot with
// the search from one without it by the query's path, a string only the search
// code holds. No type spans the Dart constant, the Xcode projects, the Podfiles
// and the workflow, or says that the script's marker is still the literal the
// Dart builds, so this gate holds them to each other (rung 5).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, exists } = require('./helpers/source');

const SCRIPT = 'scripts/check_extension_search.sh';
const ENGINE = 'lib/services/web_extension_search_engine.dart';
const LIBRARY = 'lib/services/web_extension_library.dart';
const DISTRIBUTION = 'lib/platform/app_distribution.dart';
const WORKFLOW = '.github/workflows/build-and-test.yml';
const MODES = ['Debug', 'Release', 'Profile'];

const marker = (() => {
  const m = read(SCRIPT).match(/^marker='([^']+)'$/m);
  assert.ok(m, `${SCRIPT} names its marker as marker='...'`);
  return m[1];
})();

const flavor = (() => {
  const m = read(DISTRIBUTION).match(/^const String directFlavor = '([a-z]+)';$/m);
  assert.ok(m, `${DISTRIBUTION} names the flavor as const String directFlavor = '...'`);
  return m[1];
})();

test('the marker is the path the search query is built from', () => {
  assert.ok(read(ENGINE).includes(`'${marker}'`),
    `${ENGINE} no longer builds '${marker}': update the marker in ${SCRIPT}`);
});

test('the search is built only in the direct flavor', () => {
  assert.match(read(DISTRIBUTION),
    /const AppDistribution builtFor = appFlavor == directFlavor\s*\?\s*AppDistribution\.direct\s*:\s*AppDistribution\.appStore;/);
  assert.match(read(LIBRARY),
    /const bool extensionSearchBuilt = builtFor == AppDistribution\.direct;/);
});

for (const platform of ['ios', 'macos']) {
  test(`the ${platform} project defines the ${flavor} flavor beside every mode`, () => {
    const project = read(`${platform}/Runner.xcodeproj/project.pbxproj`);
    const lists = project.match(/buildConfigurations = \(([\s\S]*?)\);/g) || [];
    assert.ok(lists.length > 0, `no configuration lists in ${platform}`);
    const want = [...MODES, ...MODES.map((m) => `${m}-${flavor}`)].sort();
    for (const list of lists) {
      const names = [...list.matchAll(/\/\* ([\w-]+) \*\//g)].map((m) => m[1]).sort();
      assert.deepEqual(names, want, `a configuration list in ${platform} lacks a ${flavor} twin`);
    }

    const scheme = `${platform}/Runner.xcodeproj/xcshareddata/xcschemes/${flavor}.xcscheme`;
    assert.ok(exists(scheme), `${scheme} is missing: Flutter finds a flavor by its shared scheme`);
    const configs = [...read(scheme).matchAll(/buildConfiguration = "([^"]+)"/g)].map((m) => m[1]);
    assert.ok(configs.length > 0, `${scheme} names no configurations`);
    for (const c of configs) {
      assert.match(c, new RegExp(`^(${MODES.join('|')})-${flavor}$`),
        `${scheme} builds ${c}, not a ${flavor} configuration`);
    }

    const podfile = read(`${platform}/Podfile`);
    for (const mode of MODES) {
      const base = podfile.match(new RegExp(`'${mode}' => :(\\w+)`));
      assert.ok(base, `${platform}/Podfile maps no '${mode}'`);
      assert.ok(podfile.includes(`'${mode}-${flavor}' => :${base[1]}`),
        `${platform}/Podfile does not map '${mode}-${flavor}' as it maps '${mode}'`);
    }
  });
}

test('CI checks a flavorless build carries no search and its direct builds do', () => {
  const workflow = read(WORKFLOW);
  const checked = (want, snapshot) => new RegExp(
    `check_extension_search\\.sh ${want} \\\\\\s*\\S*${snapshot.replace(/\./g, '\\.')}`);
  assert.match(workflow, checked('absent', 'Products/Release/webspace.app/Contents/Frameworks/App.framework/App'),
    'no absent check of the flavorless macOS build');
  assert.match(workflow, checked('present', 'Runner.app/Frameworks/App.framework/App'),
    'no present check of the iOS IPA');
  assert.match(workflow, checked('present', `Products/Release-${flavor}/webspace.app/Contents/Frameworks/App.framework/App`),
    `no present check of the macOS ${flavor} build`);
  assert.match(workflow, new RegExp(`flutter build ipa --release --no-codesign --flavor ${flavor}\\n`),
    `the IPA CI ships for sideloading is not the ${flavor} flavor`);
  assert.match(workflow, new RegExp(`flutter build macos --release --flavor ${flavor}\\n`),
    `CI builds no macOS ${flavor} flavor`);
});

test('signing for the Mac App Store refuses a build that carries it', () => {
  const sign = read('scripts/sign_macos.sh');
  assert.match(sign,
    /mas\) "\$REPO_ROOT\/scripts\/check_extension_search\.sh" absent "\$SNAPSHOT"/);
  assert.match(sign, new RegExp(`devid\\) PRODUCTS=Release-${flavor} `),
    `sign_macos.sh devid does not sign the ${flavor} build`);
});
