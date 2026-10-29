// Structural gate: an App Store build carries none of the search of
// addons.mozilla.org (WEBEXT-019).
//
// The search is compiled in only with --dart-define=WEBSPACE_EXTENSION_SEARCH,
// and scripts/check_extension_search.sh tells a built snapshot with it from one
// without it by the query's path, a string only the search code holds. No
// type can say that the script's marker is still the literal the Dart builds,
// or that the builds that stand for the App Store ones are checked, so this
// gate holds those (rung 5).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');

const SCRIPT = 'scripts/check_extension_search.sh';
const ENGINE = 'lib/services/web_extension_search_engine.dart';
const LIBRARY = 'lib/services/web_extension_library.dart';

const marker = (() => {
  const m = read(SCRIPT).match(/^marker='([^']+)'$/m);
  assert.ok(m, `${SCRIPT} names its marker as marker='...'`);
  return m[1];
})();

test('the marker is the path the search query is built from', () => {
  assert.ok(read(ENGINE).includes(`'${marker}'`),
    `${ENGINE} no longer builds '${marker}': update the marker in ${SCRIPT}`);
});

test('the search is built only with its define', () => {
  assert.match(read(LIBRARY),
    /const bool extensionSearchBuilt = bool\.fromEnvironment\(\s*'WEBSPACE_EXTENSION_SEARCH',?\s*\)/);
});

test('CI checks its iOS and macOS builds carry no search', () => {
  const workflow = read('.github/workflows/build-and-test.yml');
  for (const snapshot of [
    'Runner.app/Frameworks/App.framework/App',
    'webspace.app/Contents/Frameworks/App.framework/App',
  ]) {
    const check = new RegExp(
      `check_extension_search\\.sh absent \\\\\\s*\\S*${snapshot.replace(/\./g, '\\.')}`);
    assert.match(workflow, check, `no absent check of ${snapshot}`);
  }
  assert.doesNotMatch(workflow, /WEBSPACE_EXTENSION_SEARCH/,
    'a CI build stands for an App Store one, so none is made with the search');
});

test('signing for the Mac App Store refuses a build that carries it', () => {
  assert.match(read('scripts/sign_macos.sh'),
    /mas\) "\$REPO_ROOT\/scripts\/check_extension_search\.sh" absent "\$SNAPSHOT"/);
});
