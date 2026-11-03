// LICENSE-001 over what a build takes in: every third-party component a
// build file pulls in outside pub and Cargo (a pod, a Gradle dependency, a
// download in a CMake file, the snap or build.rs, the app's or a plugin's)
// has a row in openspec/specs/legal/components.tsv with its licence as read
// from its source, every file a pub package the app depends on builds into
// it says a licence that lets it link, and either licence lets it ship the
// way it does (openspec/specs/legal/licences.tsv). Crates are held by
// rust/webspace_adblock/build.rs. Rung 5: what a build fetches is text in its
// build files, which no type sees. The pub half reads .dart_tool, so it needs
// `flutter pub get`; CI fails without it.
//
// Not read yet: the Maven artifacts a Gradle dependency depends on in turn,
// which only Gradle's resolution names.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read } = require('./helpers/source');
const L = require('./helpers/licences');

const packages = L.pubPackages();
const needsPub = { skip: packages ? false : 'run `flutter pub get` first' };
const sites = L.pullSites([...L.buildFiles(), ...(packages ? L.pluginBuildFiles(packages) : [])]);
const components = L.registry();
const pullable = (source) => !source.startsWith('pub:');

test('LICENSE-001 pub has run, so the packages the app depends on are read', () => {
  if (!packages && process.env.CI === 'true') assert.fail('run `flutter pub get` before this test');
});

test('LICENSE-001 every component a build pulls in is in the registry', needsPub, () => {
  const missing = [...sites].filter(([s]) => !components.has(s)).map(([s, at]) => `${s} (${[...at].join(', ')})`);
  assert.deepEqual(missing, [],
    `add a row to ${L.COMPONENTS} with the licence read from the component's own source`);
});

test('LICENSE-001 the registry lists only what a build pulls in or a package ships', needsPub, () => {
  const shipped = new Set([...packages].flatMap(([name, { files }]) => files.map((f) => `pub:${name}/${f}`)));
  const stale = [...components.keys()].filter((s) => (pullable(s) ? !sites.has(s) : !shipped.has(s)));
  assert.deepEqual(stale, [], `drop these rows from ${L.COMPONENTS}: nothing pulls them in or ships them`);
});

test('LICENSE-001 every component ships under a licence that lets it ship that way', () => {
  const refused = [...components]
    .filter(([source, { licence, ships }]) => !L.allows(licence, { ships, component: source }))
    .map(([source, { licence, ships }]) => `${source}: ${licence} (${ships})`);
  assert.deepEqual(refused, [], `${L.LICENCES} allows none of these as they ship`);
});

test('LICENSE-001 every file a pub package builds into the app may link', needsPub, () => {
  assert.deepEqual(L.pubRefusals(packages, components), [],
    `${L.LICENCES} lets none of these link; a licence the readings cannot judge is read by hand into a pub: row of ${L.COMPONENTS}`);
});

// Flutter's notices carry each package's root LICENSE alone; what else a
// package ships under a licence reaches the page only through assets/licenses.
test('LICENSE-003 every notice a pub package ships beyond its root LICENSE is on the licences page', needsPub, () => {
  assert.deepEqual(L.attributionGaps(packages, { components }), []);
});

// CocoaPods writes every pod's licence as it installs them; the Podfiles lay
// that out where pubspec.yaml's assets take it up (lib/services/licenses.dart
// reads it), and what a pod compiles in beside itself has its own text.
test('LICENSE-003 every pod an Apple build links reaches the licences page', () => {
  for (const podfile of ['ios/Podfile', 'macos/Podfile']) {
    const text = read(podfile);
    const hook = text.slice(text.indexOf('post_integrate do |installer|'));
    assert.ok(text.includes('post_integrate do |installer|'), `${podfile} has no post_integrate hook`);
    assert.match(hook, /'Pods-Runner-acknowledgements\.markdown'/, `${podfile} does not read CocoaPods' acknowledgements`);
    assert.match(hook, /File\.join\(notices, 'pods\.md'\)/, `${podfile} does not lay them out as pods.md`);
    assert.match(hook, /'\.\.\/assets\/native_notices'/, `${podfile} lays them out elsewhere`);
  }
  assert.match(read('pubspec.yaml'), /^ {4}- assets\/native_notices\/$/m, 'pubspec.yaml does not bundle assets/native_notices/');
  assert.match(read('.gitignore'), /^assets\/native_notices\/\*$/m, 'the laid-out notices are not ignored');
  assert.deepEqual(L.podAttributionGaps({ components }), []);
  const planted = L.registry('pod:Lyre\tMIT AND GPL-3.0-or-later\tlinked\tits LICENSE\n');
  assert.deepEqual(L.podAttributionGaps({ components: planted, attributed: new Map() }),
    [`pod:Lyre: MIT AND GPL-3.0-or-later, and no row in ${L.ATTRIBUTIONS}`], 'a pod that compiles in more, unattributed');
});

test('the verdicts are the ones licence_cases.tsv gives', () => {
  for (const [expression, ships, component, verdict] of L.rows(read(L.CASES))) {
    assert.equal(L.allows(expression, { ships, component }), verdict === 'allowed',
      `${expression || '(empty)'} ${ships} ${component}`);
  }
});

test('each rule catches the mistake it is for', (t) => {
  const lock = [
    'PODS:',
    '  - Flutter (1.0.0)',
    '  - file_picker (0.0.1):',
    '  - Lyre (1.0.0)',
    '  - Lyre/Core (1.0.0)',
    '',
    'EXTERNAL SOURCES:',
    '  file_picker:',
    '    :path: ".symlinks/plugins/file_picker/ios"',
    '',
  ].join('\n');
  assert.deepEqual(L.pods(lock), ['pod:Lyre'], 'a third-party pod is a pull site; a plugin and the SDK are not');
  assert.deepEqual(L.gradle("    implementation 'org.example:lib:1.0'\n    testImplementation 'x:y:1'"),
    ['gradle:org.example:lib']);
  assert.deepEqual(L.urls('# https://in.a/comment\nfile(DOWNLOAD "https://example.org/a.tar.gz"\nset(X 1) # see https://a.trailing/comment'),
    ['url:https://example.org/a.tar.gz']);

  const planted = L.pullSites([['ios/Podfile.lock', ['pod:Lyre']]]);
  assert.deepEqual([...planted.keys()].filter((s) => !components.has(s)), ['pod:Lyre'],
    'a pod with no row');
  const reg = L.registry('pod:Lyre\tGPL-3.0-or-later\tlinked\tits LICENSE\nurl:x\tLGPL-2.1-or-later\tlinked\t\n');
  assert.equal(L.allows(reg.get('pod:Lyre').licence, { ships: 'linked', component: 'pod:Lyre' }), false,
    'a GPL component');
  assert.equal(L.allows(reg.get('url:x').licence, { ships: 'linked', component: 'url:x' }), false,
    'an LGPL component linked in');
  assert.equal(L.allows('GPL-2.0-only WITH Classpath-exception-2.0', { ships: 'linked', component: 'pod:Lyre' }),
    false, 'the exception taken by a component it does not name');

  const fs = require('node:fs');
  const os = require('node:os');
  const path = require('node:path');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'licence-policy-'));
  t.after(() => fs.rmSync(dir, { recursive: true, force: true }));
  const write = (rel, text) => {
    fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true });
    fs.writeFileSync(path.join(dir, rel), text);
  };
  write('LICENSE', 'Permission is hereby granted, free of charge, to any person obtaining a copy of this software');
  write('lib/a.dart', '// SPDX-License-Identifier: GPL-3.0-or-later\n');
  write('src/vendored/b.c', '/* This program is free software; you can redistribute it and/or modify it\n'
    + ' * under the terms of the GNU General Public License as published by the Free\n'
    + ' * Software Foundation. */\n');
  write('src/vendored/COPYING', '                    GNU GENERAL PUBLIC LICENSE\n       Version 3, 29 June 2007\n');
  write('third_party/LICENSE', 'Attribution-ShareAlike 3.0 Unported\n');
  write('vendor/LICENSE', 'Permission is hereby granted, free of charge, to any person obtaining a copy\n'
    + 'Parts are under the Eclipse Public License 2.0.\n');
  write('test/c.dart', '// SPDX-License-Identifier: GPL-3.0-or-later\n');
  write('android/build.gradle', "    implementation 'org.example:plugin-dep:1.0'\n");
  write('linux/CMakeLists.txt', 'FetchContent_Declare(x URL https://example.org/x.tar.gz)\n');
  const files = L.shippedFiles(dir).sort();
  assert.ok(files.includes('lib/a.dart') && !files.includes('test/c.dart'), 'a package\'s tests do not ship');
  const pkg = new Map([['p', { dir, files }]]);
  assert.deepEqual(L.pubRefusals(pkg, new Map()), [
    'pub:p/lib/a.dart: GPL-3.0-or-later',
    'pub:p/src/vendored/COPYING: a GNU licence',
    'pub:p/src/vendored/COPYING: (no licence it knows)',
    'pub:p/src/vendored/b.c: a GNU licence',
    'pub:p/third_party/LICENSE: CC-BY-SA',
    'pub:p/vendor/LICENSE: MIT AND EPL',
  ], 'an SPDX tag, a GNU notice and heading, and a restricted licence alone or beside a permissive one');
  assert.deepEqual(L.pubRefusals(pkg, L.registry('pub:p/third_party/LICENSE\tCC-BY-SA-3.0\tbuild\ttest data\n'))
    .filter((r) => r.startsWith('pub:p/third_party/')), [], 'a pub: row read by hand replaces the reading');
  assert.deepEqual(L.pluginBuildFiles(pkg).map(([at, s]) => [at, s]), [
    ['pub:p/android/build.gradle', ['gradle:org.example:plugin-dep']],
    ['pub:p/linux/CMakeLists.txt', ['url:https://example.org/x.tar.gz']],
  ], "a plugin's Gradle dependency and CMake download are pull sites");
  assert.deepEqual([...L.licencesIn('Redistribution and use in source and binary forms. '
    + 'All advertising materials mentioning features')], ['BSD-4-Clause'], 'the advertising clause is not BSD-3');

  const mit = 'Permission is hereby granted, free of charge, to any person obtaining a copy of this software';
  write('LICENSE', mit);
  write('vendor/zlib/LICENSE.txt', "This software is provided 'as-is', without any express or implied warranty.");
  write('src/lib.c', '// SPDX-License-Identifier: Apache-2.0\n');
  const vendored = new Map([['q', { dir, files: ['LICENSE', 'vendor/zlib/LICENSE.txt', 'src/lib.c'] }]]);
  assert.deepEqual(L.attributionGaps(vendored, { components: new Map(), attributed: new Map() }), [
    `pub:q/vendor/zlib/LICENSE.txt: no row in ${L.ATTRIBUTIONS}`,
    `pub:q: no row in ${L.ATTRIBUTIONS}`,
  ], 'a vendored licence file and an SPDX licence the root LICENSE does not grant, with no row');
  assert.deepEqual(L.attributionGaps(vendored, { components: new Map(), attributed: new Map([
    ['pub:q/vendor/zlib/LICENSE.txt', ['assets/licenses/kagi_bangs.txt']],
    ['pub:q', ['assets/licenses/kagi_bangs.txt']],
    ['pub:gone/LICENSE-other.md', ['assets/licenses/kagi_bangs.txt']],
  ]) }), [
    'pub:q/vendor/zlib/LICENSE.txt: its text is in none of assets/licenses/kagi_bangs.txt',
    'pub:q: Apache-2.0 granted by none of assets/licenses/kagi_bangs.txt',
    'pub:gone/LICENSE-other.md: no package ships it',
  ], 'rows whose asset carries neither the text nor the licence, and a row for nothing');
});
