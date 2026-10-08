// Layers point down (CLAUDE.md, Coding principles, rule 4). Rung 5: Dart has
// no module boundary a type could enforce, so the import graph is read here.
// DEBT is what already pointed up when the rule was written; it only shrinks.
const test = require('node:test');
const assert = require('node:assert');
const { read } = require('./helpers/source');
const { layerOf, sources, upward } = require('./helpers/layers');

const DEBT = new Set([
  'lib/services/cookie_isolation.dart -> lib/web_view_model.dart',
  'lib/services/settings_backup.dart -> lib/web_view_model.dart',
  'lib/services/settings_import_engine.dart -> lib/web_view_model.dart',
  'lib/services/site_activation_engine.dart -> lib/web_view_model.dart',
  'lib/services/site_unload_engine.dart -> lib/web_view_model.dart',
  'lib/services/startup_restore_engine.dart -> lib/web_view_model.dart',
  'lib/services/webview_downloads.dart -> lib/widgets/root_messenger.dart',
  'lib/services/webview.dart -> lib/widgets/surface_nudge_scope.dart',
  'lib/services/webview_host_hooks.dart -> lib/web_view_model.dart',
]);

test('no file imports a layer above its own, beyond the recorded debt', () => {
  const fresh = upward().filter((e) => !DEBT.has(e));
  assert.deepEqual(fresh, [], 'import points up; move the shared type down or invert the dependency');
});

test('the debt list holds only edges that still exist', () => {
  const live = new Set(upward());
  const paid = [...DEBT].filter((e) => !live.has(e));
  assert.deepEqual(paid, [], 'paid off: delete these from DEBT');
});

test('platform is importable from plain Dart', () => {
  for (const file of sources.filter((f) => layerOf(f) === 'platform')) {
    for (const line of read(file).split('\n').filter((l) => /^\s*(import|export)\s/.test(l))) {
      assert.doesNotMatch(line, /package:flutter|package:path_provider|package:webspace\/(?!platform\/)/, `${file}: ${line.trim()}`);
    }
  }
});

test('engines are pure: no Flutter import', () => {
  for (const file of sources.filter((f) => /^lib\/services\/[^/]+_engine\.dart$/.test(f))) {
    assert.doesNotMatch(read(file), /^import\s+'package:flutter\//m, file);
  }
});
