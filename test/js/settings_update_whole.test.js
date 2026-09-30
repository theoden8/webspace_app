// BUG-022: every settings update sends the object the webview was created
// with, changed in the fields the update owns.
//
// The plugin's setSettings sends every field of the object it is given, and
// the Dart constructor defaults most of them (JavaScript on, third-party
// cookies on, incognito off, mobile content mode). Android and iOS/macOS apply
// each field that differs from what the webview holds and Linux replaces its
// settings wholesale, so a freshly built object resets every per-site setting
// it leaves out. It happened twice before the class was named: textZoom
// (#246) and useHybridComposition (#635).

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const lib = path.join(repoRoot, 'lib');

function dartFiles(dir) {
  const out = [];
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (entry.name === 'gen') continue;
      out.push(...dartFiles(full));
    } else if (entry.name.endsWith('.dart')) {
      out.push(full);
    }
  }
  return out;
}

function callSites(src, name) {
  const sites = [];
  const re = new RegExp(`\\b${name}\\(`, 'g');
  let m;
  while ((m = re.exec(src)) !== null) {
    let depth = 1;
    let i = m.index + m[0].length;
    while (i < src.length && depth > 0) {
      if (src[i] === '(') depth++;
      else if (src[i] === ')') depth--;
      i++;
    }
    sites.push({
      line: src.slice(0, m.index).split('\n').length,
      args: src.slice(m.index + m[0].length, i - 1),
    });
  }
  return sites;
}

test('every setSettings call sends the creation settings', () => {
  const offending = [];
  let count = 0;
  for (const file of dartFiles(lib)) {
    const src = fs.readFileSync(file, 'utf8');
    for (const site of callSites(src, 'setSettings')) {
      if (/^\s*\{/.test(site.args) || site.args.trim() === '') continue;
      count++;
      if (!/^\s*settings:\s*_settings\s*,?\s*$/.test(site.args)) {
        offending.push(`${path.relative(repoRoot, file)}:${site.line}`);
      }
    }
  }
  assert.ok(count >= 2, `scan found only ${count} setSettings calls; the parser broke`);
  assert.deepEqual(offending, [],
    'these setSettings calls send something other than the creation settings; ' +
    'change the field on _settings and send it whole');
});

test('each controller wrapper holds the settings its webview was created with', () => {
  const src = fs.readFileSync(path.join(lib, 'services', 'webview.dart'), 'utf8');
  const sites = callSites(src, '_WebViewController')
    .filter((s) => !/^\s*this\._c/.test(s.args));
  assert.ok(sites.length >= 2, `found only ${sites.length} wrapper constructions`);
  const offending = sites
    .filter((s) => !/\bsettings:\s*settings\b/.test(s.args))
    .map((s) => `lib/services/webview.dart:${s.line}`);
  assert.deepEqual(offending, [],
    'a wrapper built with anything but the creation settings would send it ' +
    'as the webview state on the next update');
});
