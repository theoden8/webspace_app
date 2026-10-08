// PAUSE-032: one Android composition mode per process, carried by every
// settings object the app hands the plugin.
//
// The fork's setSettings replaces a webview's native settings wholesale, and
// the Dart InAppWebViewSettings constructor defaults useHybridComposition to
// true. A settings object that omits the field therefore tells a texture-mode
// webview it is in hybrid composition, and the plugin's input-connection and
// text-selection code branches on that flag. Nothing fails loudly: the page
// keeps rendering while the keyboard or selection menu quietly misbehaves.

const test = require('node:test');
const assert = require('node:assert/strict');
const { read, dartFiles } = require('./helpers/source');

// The argument list of each `InAppWebViewSettings(` call, or the cascade that
// follows one, up to the end of its statement.
function settingsSites(src) {
  const sites = [];
  const re = /InAppWebViewSettings\(/g;
  let m;
  while ((m = re.exec(src)) !== null) {
    let depth = 1;
    let i = m.index + m[0].length;
    while (i < src.length && depth > 0) {
      if (src[i] === '(') depth++;
      else if (src[i] === ')') depth--;
      i++;
    }
    let end = i;
    if (/^\s*\.\./.test(src.slice(i, i + 40))) {
      // A cascade runs to the first `;` outside a line comment.
      let j = i;
      for (;;) {
        const nl = src.indexOf('\n', j);
        const line = src.slice(j, nl < 0 ? undefined : nl).replace(/\/\/.*$/, '');
        const semi = line.indexOf(';');
        if (semi >= 0) { end = j + semi; break; }
        if (nl < 0) { end = src.length; break; }
        j = nl + 1;
      }
    }
    const line = src.slice(0, m.index).split('\n').length;
    sites.push({ line, text: src.slice(m.index, end) });
  }
  return sites;
}

test('every InAppWebViewSettings built in lib/ carries the composition mode', () => {
  const missing = [];
  let count = 0;
  for (const file of dartFiles()) {
    const src = read(file);
    for (const site of settingsSites(src)) {
      count++;
      if (!/useHybridComposition\s*(:|=)\s*WebViewFactory\.hybridComposition/.test(site.text)) {
        missing.push(`${file}:${site.line}`);
      }
    }
  }
  assert.ok(count >= 3, `scan found only ${count} settings objects; the parser broke`);
  assert.deepEqual(missing, [],
    'these settings objects omit useHybridComposition, so the Dart default ' +
    '(true) would reach a webview created in texture mode');
});

test('the mode is set once, at launch', () => {
  const assignments = [];
  for (const file of dartFiles()) {
    const src = read(file);
    const re = /WebViewFactory\.hybridComposition\s*=[^=]/g;
    let m;
    while ((m = re.exec(src)) !== null) {
      assignments.push(`${file}:${src.slice(0, m.index).split('\n').length}`);
    }
  }
  assert.equal(assignments.length, 1,
    `WebViewFactory.hybridComposition must be assigned exactly once (at launch), ` +
    `found: ${assignments.join(', ')}. Changing it while webviews exist would ` +
    'hand them a mode they were not created in.');
  assert.match(assignments[0], /^lib\/main\.dart:/);
});

test('hybrid composition is the default, texture mode an experiment', () => {
  const webview = read('lib/services/webview.dart');
  assert.match(webview, /static bool hybridComposition = true;/);
  const main = read('lib/main.dart');
  assert.match(main,
    /WebViewFactory\.hybridComposition = !ExperimentalFeaturesService\.instance\s*\.isEnabled\(ExperimentalFeature\.textureRendering\);/,
    'texture mode must be reachable only through the DEVTOOLS-011 gate');
  const experimental = read('lib/services/experimental_features_service.dart');
  assert.match(experimental,
    /textureRendering\(AppPref\.experimentalTextureRendering\)/);
  assert.match(read('lib/settings/app_prefs.dart'),
    /experimentalTextureRendering\('experimentalTextureRendering', false\)/);
});
