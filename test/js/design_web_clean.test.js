// Gate for DESIGN-001: lib/main.dart and every file under lib/widgets and
// lib/screens compile for web, so the design gallery and the designer's app
// can show them.
//
// Rung 5: Dart has no type for "this library's import closure avoids
// dart:io", and the web compile that would refuse one is a Flutter build no
// counted check runs. The scan is tool/design_gallery/web_clean.js, the walk
// `npm run design:check` prints, over import and export directives as a web
// compile takes them.
//
// Planted mistake: `import 'dart:io';` added to lib/widgets/toast.dart made
// the first test fail naming that file; each case below plants one shape of
// the same mistake in a tree of its own.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { scan } = require('../../tool/design_gallery/web_clean');

const ROOT = path.resolve(__dirname, '../..');

test('DESIGN-001: main.dart and every UI file avoid dart:io and dart:ffi', () => {
  const { files, blocked } = scan({ root: ROOT });
  assert.ok(files.includes('lib/main.dart'), 'main.dart is scanned');
  assert.ok(files.length > 100, `only ${files.length} UI files found`);
  assert.deepEqual(
    blocked.map(({ file, chain, leaf }) => `${[...chain, leaf].join(' -> ')}`),
    [],
    `${blocked[0]?.file} no longer compiles for web: route the platform call through a seam`,
  );
});

function tree(files) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'web-clean-'));
  for (const dir of ['lib/widgets', 'lib/screens', 'lib/services', 'lib/platform']) {
    fs.mkdirSync(path.join(root, dir), { recursive: true });
  }
  fs.writeFileSync(path.join(root, 'lib/main.dart'), "import 'package:flutter/material.dart';\n");
  for (const [file, source] of Object.entries(files)) {
    fs.mkdirSync(path.dirname(path.join(root, file)), { recursive: true });
    fs.writeFileSync(path.join(root, file), source);
  }
  test.after(() => fs.rmSync(root, { recursive: true, force: true }));
  return root;
}

const chains = (root) => scan({ root }).blocked.map(({ chain, leaf }) => [...chain, leaf].join(' -> '));

test('DESIGN-001: a widget that imports a service importing dart:io is named with its chain', () => {
  const root = tree({
    'lib/widgets/w.dart': "import 'package:webspace/services/s.dart';\n",
    'lib/services/s.dart': "import 'dart:io';\n",
  });
  assert.deepEqual(chains(root), ['lib/widgets/w.dart -> lib/services/s.dart -> dart:io']);
});

test('DESIGN-001: a re-export carries dart:io into the closure', () => {
  const root = tree({
    'lib/screens/s.dart': "import '../services/barrel.dart';\n",
    'lib/services/barrel.dart': "export 'native.dart';\n",
    'lib/services/native.dart': "import 'dart:ffi';\n",
  });
  assert.deepEqual(chains(root), [
    'lib/screens/s.dart -> lib/services/barrel.dart -> lib/services/native.dart -> dart:ffi',
  ]);
});

test('DESIGN-001: main.dart and nested UI directories are scanned', () => {
  const root = tree({
    'lib/main.dart': "import 'dart:io';\n",
    'lib/widgets/deep/w.dart': "import 'dart:io';\n",
  });
  assert.deepEqual(chains(root), ['lib/main.dart -> dart:io', 'lib/widgets/deep/w.dart -> dart:io']);
});

test('DESIGN-001: the seam, a conditional export whose io half imports dart:io, is clean', () => {
  const root = tree({
    'lib/widgets/w.dart': "import 'package:webspace/platform/host.dart';\n",
    'lib/platform/host.dart': "export 'host_web.dart' if (dart.library.io) 'host_io.dart';\n",
    'lib/platform/host_web.dart': 'bool get hostIsAndroid => false;\n',
    'lib/platform/host_io.dart': "import 'dart:io';\n",
  });
  assert.deepEqual(chains(root), []);
});
