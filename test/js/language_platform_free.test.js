// Language on every platform alike (LANG-005).
//
// The Accept-Language header and the page's language override are built from
// the site's posture alone, so a site sends and reports one language on
// Android, iOS and macOS. No type can say a function takes no platform input,
// so this gate reads the builders: none of them names the host platform, and
// the page script reads nothing of the device to decide what it reports.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, methodBody } = require('./helpers/source');

const PLATFORM = /\bhostIs\w+|\bPlatform\.|\bdefaultTargetPlatform\b|\bTargetPlatform\./;
const DEVICE = /navigator\.(?:platform|userAgent|userAgentData|oscpu)/;

test('LANG-005: the header and the override are built without the platform', () => {
  for (const [name, file] of [
    ['navigationHeaders', 'lib/services/webview.dart'],
    ['_scopedShims', 'lib/services/page_scripts.dart'],
    ['buildLanguageShim', 'lib/services/language_shim.dart'],
  ]) {
    assert.doesNotMatch(methodBody(name, { file }), PLATFORM, `${name} in ${file}`);
  }
  assert.doesNotMatch(read('lib/services/language_shim.dart'), /package:webspace\/platform\//,
    'language_shim.dart imports nothing of the platform layer');
});

test('LANG-005: the page script reports the configured language, whatever the device', () => {
  assert.doesNotMatch(read('lib/js/language.js'), DEVICE);
});
