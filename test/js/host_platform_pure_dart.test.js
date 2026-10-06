// host_platform is the dart:io seam that plain-Dart code reaches (the shim
// builders, through the models they import, are run by
// tool/dump_shim_js.dart under `dart run`). A Flutter import anywhere in its
// closure makes that tool fail on dart:ui, so the platform layer imports no
// Flutter plugin and no service; those belong in host_storage.
const test = require('node:test');
const assert = require('node:assert');
const { read } = require('./helpers/source');

const PURE = [
  'lib/platform/host_platform.dart',
  'lib/platform/host_platform_io.dart',
  'lib/platform/host_platform_web.dart',
];

for (const file of PURE) {
  test(`${file} reaches neither Flutter nor a service`, () => {
    const directives = read(file)
      .split('\n')
      .filter((line) => /^\s*(import|export)\s/.test(line));
    for (const line of directives) {
      assert.doesNotMatch(line, /package:flutter|package:path_provider/, `${file}: ${line.trim()}`);
      assert.doesNotMatch(line, /package:webspace\/services\//, `${file}: ${line.trim()}`);
    }
  });
}
