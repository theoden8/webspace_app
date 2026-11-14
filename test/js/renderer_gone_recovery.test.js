// Renderer-gone recovery gate (PAUSE-013 / PAUSE-014 / BUG-002). The black-screen
// bug is a DEAD renderer (the OS killed the web-content process); recovery
// disposes the webview (webview=null; controller=null) and rebuilds. This asserts
// the recovery stays WIRED, so a refactor can't silently drop a platform event or
// the proactive probe and re-open BUG-002. Behavioural coverage of the recovery
// itself lives in test/webview_renderer_gone_test.dart.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, methodBody } = require('./helpers/source');

test('both platform renderer-death events route to onRendererGone', () => {
  const src = read('lib/services/webview.dart');
  assert.match(src, /onRenderProcessGone:/, 'Android renderer-death event must be handled');
  assert.match(
    src,
    /onWebContentProcessDidTerminate:/,
    'iOS/macOS content-process-death event must be handled',
  );
  const calls = (src.match(/config\.onRendererGone\?\.call\(/g) || []).length;
  assert.ok(calls >= 2, `both events must call onRendererGone, found ${calls}`);
});

test('onRendererGone is wired to the destroy-and-rebuild recovery', () => {
  // The site's webview hands a renderer death to its host, which lets the
  // webview go through the one owner of a let-go (LetGoTable) and rebuilds.
  assert.match(
    read('lib/web_view_model.dart'),
    /onRendererGone:\s*\(\{required didCrash\}\)\s*=>\s*hooks\.rendererGone\(this, didCrash: didCrash\),/,
    'the config callback must hand the death to the host',
  );
  assert.match(read('lib/screens/webspace_page.dart'),
    /rendererGone:\s*_lifecycle\.rendererGone,/,
    'the page must answer it with the lifecycle controller');
  const lifecycle = 'lib/controllers/app_lifecycle_controller.dart';
  const answer = methodBody('rendererGone', { file: lifecycle });
  assert.match(answer,
    /LetGoTable\.letGo\(_sites, site: model, end: WebViewEnd\.rendererGone\)/,
    'the answer must let the dead webview go');
  assert.match(answer, /_host\.rebuild\(\)/, 'and rebuild the page');
  assert.match(methodBody('probeRenderer', { file: lifecycle }),
    /rendererGone\(model, didCrash: false\)/,
    'the probe must join the same recovery');
  // The let-go must DISPOSE the dead instance (the fix), not just log, on
  // either arm, through the one teardown, so what a webview holds goes with
  // it (BGAUDIO-010's controls).
  const letGo = methodBody('letGo', { file: 'lib/controllers/let_go_table.dart' });
  assert.match(letGo, /table\.runEnvironment\(/, 'the let-go the model takes');
  assert.match(letGo, /\.disposeWebView\(/, 'and the one it takes none of');
  assert.match(read('lib/controllers/let_go_table.dart'),
    /\.letGoWebView\(commit: c\.commit, end: _end\.from\(c\)\)/,
    "the step's arm must let the webview go");
  const file = 'lib/web_view_model.dart';
  for (const owner of ['disposeWebView', 'letGoWebView']) {
    assert.match(methodBody(owner, { file }), /\b_letGoOfWebView\(view: _leaving\(end\)\)/,
      `${owner} must let go of the webview through _letGoOfWebView`);
  }
  assert.match(methodBody('_leaving', { file }), /WebViewEnd\.rendererGone => null/,
    'a dead renderer is not waited on to quiet');
  const teardown = methodBody('_letGoOfWebView', { file });
  assert.match(teardown, /webview\s*=\s*null/, 'must drop the dead cached widget');
  assert.match(teardown, /controller\s*=\s*null/, 'must drop the dead controller');
});

test('the proactive probe runs on >=2 activation paths (PAUSE-014)', () => {
  // The resume and every site activation probe. The offscreen renderer
  // death, the case the platform event misses, is only caught by this probe,
  // so dropping a call site re-opens BUG-002.
  const lifecycle = read('lib/controllers/app_lifecycle_controller.dart');
  assert.match(lifecycle, /probeRenderer\(_sites\.models\[probeIdx\], trigger: 'resume'\)/,
    'the resume must probe the site on screen');
  assert.match(read('lib/controllers/site_activation_controller.dart'),
    /_host\.probeRenderer\(target, trigger: 'site-switch'\)/,
    'every activation must probe its target');
  assert.match(read('lib/screens/webspace_page.dart'),
    /probeRenderer\(WebViewModel model, \{required String trigger\}\) =>\s*_s\._lifecycle\.probeRenderer\(/,
    'the activation host must hand the probe to the lifecycle controller');
});

test('nested InAppWebViewScreen wires renderer-gone recovery (BUG-002 gap #1)', () => {
  const src = read('lib/screens/inappbrowser.dart');
  assert.match(
    src,
    /onRendererGone:\s*_handleRendererGone,/,
    'nested WebViewConfig must wire onRendererGone',
  );
  // The handler must REMOUNT the dead webview (bump the key), not just log.
  const def = src.slice(src.indexOf('void _handleRendererGone'));
  assert.match(def, /_rendererGen\+\+/, 'recovery must bump the remount key');
  // And a proactive probe on resume (the offscreen case the event misses).
  assert.match(src, /didChangeAppLifecycleState/, 'nested screen must hook resume');
  assert.match(src, /_surface\.rendererGone\(/, 'nested probe must use the shared probe');
  assert.match(read('lib/controllers/surface_repaint_controller.dart'),
    /rendererProbeIndicatesGone\(result\)/, 'the shared probe must use the gone predicate');
});

test('rendererProbeIndicatesGone treats only null as gone', () => {
  const src = read('lib/services/webview_controller.dart');
  // A regression that flags 0 / -1 / positive height as "gone" would reload-loop
  // a healthy page. The predicate must be exactly `== null`.
  assert.match(
    src,
    /bool\s+rendererProbeIndicatesGone\([^)]*\)\s*=>\s*\w+\s*==\s*null\s*;/,
    'predicate must be `probeResult == null`',
  );
});
