// Structural gate: what a platform channel's two failures mean is said at
// each call, as an arm of a `switch` over `ChannelReply`
// (lib/services/channel_reply.dart), whose `ask`, `askList` and `askMap` hold
// the one try that catches them.
//
// About fifty `try { invokeMethod } on PlatformException on
// MissingPluginException` blocks once each decided alone what a missing plugin
// and a refusal meant, and some forgot one of the two. Dart cannot stop a
// catch clause naming a type, so the clause is what this refuses (rung 5).

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles, code, lineAt } = require('./helpers/source');

const OWNER = 'lib/services/channel_reply.dart';
const CAUGHT = /\bon\s+MissingPluginException\b/g;

// A catch kept on purpose, with why it is not a channel call `ask` can make.
const KEPT = {
  // The container engine's bridge, which the activation's tables call.
  'lib/services/container_native.dart': 4,
  // attach: the DNS table's write tells the views through it (DNS-022).
  'lib/services/web_intercept_native.dart': 1,
  // The plugin's cache API and controller; webViewDestroyed is awaited by
  // the wake's close and ProcessRoute.leave (PROXY-008).
  'lib/services/webview_controller.dart': 3,
  // A wake's headless check, closed inside the wake's table (NOTIF-021).
  'lib/services/headless_site_check.dart': 1,
  // The plugin's ProxyController and WebViewFeature.
  'lib/services/webview_proxy.dart': 4,
  // The plugin's ContainerController.
  'lib/services/web_extension_native.dart': 3,
  // The plugin's CookieManager, the jar's one funnel (ISO-003).
  'lib/services/cookie_manager.dart': 1,
  // flutter_secure_storage.
  'lib/services/keystore.dart': 1,
  // file_picker, and the xdg portal on Linux.
  'lib/services/file_dialog_io.dart': 1,
  'lib/services/file_dialog_web.dart': 1,
  // SharedPreferences and the app's files.
  'lib/services/block_stats_service.dart': 2,
  'lib/services/top_sites_service.dart': 1,
  'lib/services/site_search_list_service.dart': 1,
  'lib/controllers/page_orphan_sweep.dart': 1,
  // The keychain's AEAD key and the state files.
  'lib/services/webview_state_secure_storage.dart': 1,
  // The plugin's ServiceWorkerController.
  'lib/main.dart': 1,
  // package_info_plus.
  'lib/screens/location_picker.dart': 1,
  'lib/services/content_blocker_service.dart': 1,
  // ContentRuleListStore, an interface a fake stands in for.
  'lib/services/content_rule_lists.dart': 1,
  // The plugin's getDefaultUserAgent.
  'lib/services/host_user_agent.dart': 1,
  // The plugin's webview controller.
  'lib/services/page_focus.dart': 1,
  'lib/services/page_phase.dart': 1,
  'lib/services/webview_downloads.dart': 1,
  // A headless webview of the plugin's.
  'lib/services/proxy_router_probe.dart': 1,
  'lib/services/router_attribution.dart': 1,
  // The plugin's PullToRefreshController.
  'lib/services/pull_to_refresh_gate.dart': 1,
  // The plugin's WebViewEnvironment.
  'lib/services/site_icon_fetcher.dart': 1,
  // url_launcher.
  'lib/widgets/external_url_prompt.dart': 1,
};

function caught(rel, src) {
  const text = code(src);
  return [...text.matchAll(CAUGHT)].map((m) => `${rel}:${lineAt(text, m.index)}`);
}

test('only channel_reply.dart catches MissingPluginException around a channel', () => {
  const found = {};
  for (const rel of dartFiles()) {
    if (rel === OWNER) continue;
    const hits = caught(rel, read(rel));
    if (hits.length) found[rel] = hits;
  }
  const unexpected = Object.entries(found)
    .filter(([rel, hits]) => hits.length !== KEPT[rel])
    .flatMap(([, hits]) => hits);
  assert.deepEqual(unexpected, [],
    'switch over channel.ask(method) and say what each ChannelReply means');
  for (const rel of Object.keys(KEPT)) {
    assert.ok(found[rel], `${rel} no longer catches it; drop it from KEPT`);
  }
  assert.equal(caught(OWNER, read(OWNER)).length, 1);
});

test('planted: a hand-written catch is caught, a mention in a comment is not', () => {
  const planted = [
    'Future<void> f() async {',
    '  try {',
    "    await _channel.invokeMethod<void>('x');",
    '  } on PlatformException {',
    '  } on MissingPluginException {',
    '  }',
    '}',
    '',
  ].join('\n');
  assert.deepEqual(caught('planted.dart', planted), ['planted.dart:5']);
  assert.deepEqual(caught('planted.dart', '// on MissingPluginException\n'), []);
});
