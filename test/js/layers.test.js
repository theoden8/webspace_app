// Layers point down (CLAUDE.md, Coding principles, rule 4). Rung 5: Dart has
// no module boundary a type could enforce, so the import graph is read here.
// DEBT is what already pointed up when the rule was written; it only shrinks.
const test = require('node:test');
const assert = require('node:assert');
const { read } = require('./helpers/source');
const { layerOf, sources, upward } = require('./helpers/layers');

const DEBT = new Set([
  'lib/services/archive_membership_engine.dart -> lib/webspace_model.dart',
  'lib/services/cookie_isolation.dart -> lib/web_view_model.dart',
  'lib/services/cookie_secure_storage.dart -> lib/demo_data.dart',
  'lib/services/diag_seed.dart -> lib/demo_data.dart',
  'lib/services/diag_seed.dart -> lib/web_view_model.dart',
  'lib/services/diag_seed.dart -> lib/webspace_model.dart',
  'lib/services/navigation_decision_engine.dart -> lib/web_view_model.dart',
  'lib/services/settings_backup.dart -> lib/web_view_model.dart',
  'lib/services/settings_backup.dart -> lib/webspace_model.dart',
  'lib/services/settings_import_engine.dart -> lib/web_view_model.dart',
  'lib/services/settings_import_engine.dart -> lib/webspace_model.dart',
  'lib/services/site_activation_engine.dart -> lib/web_view_model.dart',
  'lib/services/site_lifecycle_engine.dart -> lib/webspace_model.dart',
  'lib/services/site_unload_engine.dart -> lib/web_view_model.dart',
  'lib/services/startup_restore_engine.dart -> lib/web_view_model.dart',
  'lib/services/suggested_sites_service.dart -> lib/screens/add_site.dart',
  'lib/services/webspace_selection_engine.dart -> lib/webspace_model.dart',
  'lib/services/webview.dart -> lib/widgets/root_messenger.dart',
  'lib/services/webview.dart -> lib/widgets/surface_nudge_scope.dart',
  'lib/services/webview_host_hooks.dart -> lib/web_view_model.dart',
  'lib/settings/app_prefs.dart -> lib/demo_data.dart',
  'lib/settings/datasets.dart -> lib/services/clearurl_service.dart',
  'lib/settings/datasets.dart -> lib/services/dns_block_service.dart',
  'lib/settings/datasets.dart -> lib/services/firefox_user_agent_service.dart',
  'lib/settings/datasets.dart -> lib/services/localcdn_service.dart',
  'lib/settings/datasets.dart -> lib/services/site_search_list_service.dart',
  'lib/settings/datasets.dart -> lib/services/timezone_location_service.dart',
  'lib/settings/datasets.dart -> lib/services/web_intercept_native.dart',
  'lib/settings/datasets.dart -> lib/widgets/dataset_tile.dart',
  'lib/settings/global_outbound_proxy.dart -> lib/services/log_service.dart',
  'lib/settings/global_outbound_proxy.dart -> lib/services/proxy_password_secure_storage.dart',
  'lib/settings/proxy_library.dart -> lib/services/log_service.dart',
  'lib/settings/proxy_library.dart -> lib/services/proxy_password_secure_storage.dart',
  'lib/settings/user_script.dart -> lib/services/host_resolution.dart',
  'lib/web_view_model.dart -> lib/widgets/external_url_prompt.dart',
  'lib/web_view_model.dart -> lib/widgets/tor_bootstrap.dart',
  'lib/web_view_model.dart -> lib/widgets/unproxied_block.dart',
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
