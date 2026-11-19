// TOR-012 gate: the Tor marks describe the network, never name the app.
//
// The Tor Project's trademark policy lets an open-source project say it
// routes through the Tor network and forbids "Tor" in a product name, title
// or identifier; App Store Review Guideline 5.2.5 rejects a third-party mark
// used without rights. Rung 5: every place a build or a store reads the app's
// name or identity is a file, and no type sees across them. The English
// strings are held to words that brand rather than describe; a translation
// follows its English source, which l10n_language.test.js holds it to.

const test = require('node:test');
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');
const { REPO, read } = require('./helpers/source');

const TOR = /\btor\b/i;

/** Every value a build or a store shows as the app's name, or uses as its id. */
function names() {
  const out = [];
  const each = (rel, re) => {
    for (const m of read(rel).matchAll(re)) out.push({ where: rel, value: m[1] });
  };
  each('ios/Runner/Info.plist', /<key>CFBundle(?:Display)?Name<\/key>\s*<string>([^<]*)</g);
  each('macos/Runner/Configs/AppInfo.xcconfig', /^PRODUCT_(?:NAME|BUNDLE_IDENTIFIER)\s*=\s*(.*)$/gm);
  for (const rel of ['ios/Runner.xcodeproj/project.pbxproj', 'macos/Runner.xcodeproj/project.pbxproj']) {
    each(rel, /PRODUCT_BUNDLE_IDENTIFIER = "?([^";]*)/g);
  }
  each('android/app/build.gradle', /applicationId(?:Suffix)?\s+"([^"]*)"/g);
  each('android/app/build.gradle', /resValue\s+"string",\s*"app_name",\s*"([^"]*)"/g);
  each('linux/CMakeLists.txt', /set\((?:BINARY_NAME|APPLICATION_ID)\s+"([^"]*)"/g);
  each('linux/my_application.cc', /gtk_(?:header_bar|window)_set_title\([^,]*,\s*"([^"]*)"/g);
  each('linux/webspace.desktop.in', /^(?:Name|GenericName)=(.*)$/gm);
  each('linux/webspace.metainfo.xml.in', /<(?:name|summary)>([^<]*)</g);
  each('pubspec.yaml', /^name:\s*(.*)$/gm);
  for (const f of ['title.txt', 'short_description.txt']) {
    out.push({ where: f, value: read(`fastlane/metadata/android/en-US/${f}`) });
  }
  for (const rel of tracked('lib/l10n').filter((f) => /\/app_[\w]+\.arb$/.test(f))) {
    out.push({ where: rel, value: JSON.parse(read(rel)).appTitle });
  }
  return out;
}

function tracked(dir) {
  return execFileSync('git', ['ls-files', '--', dir], { cwd: REPO, encoding: 'utf8' })
    .split('\n')
    .filter(Boolean);
}

test('TOR-012: names() reads every place the app is named', () => {
  const where = new Set(names().map((n) => n.where));
  for (const rel of [
    'ios/Runner/Info.plist', 'macos/Runner/Configs/AppInfo.xcconfig',
    'ios/Runner.xcodeproj/project.pbxproj', 'macos/Runner.xcodeproj/project.pbxproj',
    'android/app/build.gradle', 'linux/CMakeLists.txt', 'linux/my_application.cc',
    'linux/webspace.desktop.in', 'linux/webspace.metainfo.xml.in', 'pubspec.yaml',
    'title.txt', 'short_description.txt', 'lib/l10n/app_en.arb',
  ]) {
    assert.ok(where.has(rel), `${rel} no longer yields a name: point the pattern at where it moved`);
  }
});

test('TOR-012: no app name, title or identifier carries "Tor"', () => {
  const branded = names().filter((n) => TOR.test(n.value));
  assert.deepEqual(branded, [],
    'the Tor marks may describe the network the app routes through, never name it');
});

test('TOR-012: no onion mark ships as an icon or badge', () => {
  const images = /\.(png|jpe?g|webp|svg|pdf|icns|ico|xml)$/i;
  const roots = ['assets', 'ios/Runner/Assets.xcassets', 'macos/Runner/Assets.xcassets',
    'android/app/src', 'linux', 'web'];
  const marks = roots.flatMap(tracked)
    .filter((f) => images.test(f) || f.endsWith('.imageset/Contents.json'))
    .filter((f) => /onion|(^|[^a-z])tor([^a-z]|$)/i.test(f.split('/').slice(-2).join('/')));
  assert.deepEqual(marks, [], 'an onion or Tor image is the Tor Project\'s mark');
});

test('TOR-012: the English strings describe the network, never brand a feature', () => {
  const arb = JSON.parse(read('lib/l10n/app_en.arb'));
  const brands = [
    /\bWebSpace\s+Tor\b|\bTor\s+(?:for\s+)?WebSpace\b/i,
    /\bTor\s+(?:mode|edition|tabs?)\b/i,
    /\b(?:endorsed|affiliated|sponsored|certified|approved|official)\b[^.]*\bTor\b/i,
    /\bTor\b[^.]*\b(?:endorses|partners?)\b/i,
  ];
  const branded = Object.entries(arb)
    .filter(([k, v]) => !k.startsWith('@') && typeof v === 'string')
    .filter(([, v]) => brands.some((re) => re.test(v)))
    .map(([k, v]) => `${k}: ${v}`);
  assert.deepEqual(branded, []);
});
