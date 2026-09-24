// File-import synthetic-URL funnel gate (IMPORT-005 / BUG-017).
//
// A file import renders its stored bytes under a synthetic `file:///<name>`
// URL with nothing behind it. Every path that hands that URL to the engine as a
// load fails: Chromium shows ERR_FILE_NOT_FOUND, and WebKit's reload (which
// re-requests the document URL and drops the bytes) fails provisionally without
// an onLoadStop, so pull-to-refresh spins forever. The fixes before this one
// each closed one path (a missing import, the Android restore) and the next
// path reopened it, so the rule now lives at the one seam model code loads
// through: `_WebViewController`. This gate fails CI if that seam stops
// consulting the import document, or if model code goes around it.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { blockAfter } = require('./helpers/dart_blocks');

const repoRoot = path.resolve(__dirname, '..', '..');
const rel = 'lib/services/webview.dart';
const src = fs.readFileSync(path.join(repoRoot, rel), 'utf8');

const wrapper = blockAfter(
  src, 'class _WebViewController implements WebViewController {', null, rel);

test('reload re-renders the import before it can reach the engine', () => {
  const body = blockAfter(wrapper, 'Future<void> reload()', null, rel);
  const guard = body.indexOf('FileImportDocument.rendersOnReload(');
  const native = body.indexOf('_c.reload()');
  assert.notEqual(guard, -1, 'reload() must consult rendersOnReload');
  assert.notEqual(native, -1, 'reload() must still reload natively otherwise');
  assert.ok(guard < native, 'the import check must precede _c.reload()');
  assert.match(body.slice(guard, native), /loadHtmlString\(\s*fileImport\.html/,
      'the guarded branch must render the import document');
});

test('a load of the import URL renders the import', () => {
  const body = blockAfter(wrapper, 'Future<void> loadUrl(', ') {', rel);
  const guard = body.indexOf('.isLoadOf(url)');
  const native = body.indexOf('_c.loadUrl(');
  assert.notEqual(guard, -1, 'loadUrl() must consult isLoadOf');
  assert.ok(native > guard, 'the import check must precede _c.loadUrl()');
  assert.match(body.slice(guard, native), /loadHtmlString\(\s*fileImport\.html/,
      'the guarded branch must render the import document');
});

test('the wrapper has no other native reload or load', () => {
  assert.equal((wrapper.match(/_c\.reload\(/g) || []).length, 1);
  assert.equal((wrapper.match(/_c\.loadUrl\(/g) || []).length, 1);
});

test('the controller handed to the model carries the import document', () => {
  const created = blockAfter(src, 'onWebViewCreated: (controller) async {', null, rel);
  const ctor = created.match(/_WebViewController\(([\s\S]*?)\);/);
  assert.ok(ctor, 'onWebViewCreated must build a _WebViewController');
  assert.match(ctor[1], /fileImport:\s*fileImport/,
      'the wrapper built for onControllerCreated must receive fileImport');
  assert.match(created, /onControllerCreated\(wrappedController\)/);
});

test('initialData and the wrapper render the same import document', () => {
  assert.match(src, /final fileImport = FileImportDocument\.of\(/);
  assert.match(src, /data:\s*fileImport\?\.html\s*\?\?\s*config\.initialHtml!/,
      'initialData must render fileImport.html for an import');
});

test('model code does not load through the raw native controller', () => {
  const offenders = [];
  const walk = (dir) => {
    for (const e of fs.readdirSync(path.join(repoRoot, dir), { withFileTypes: true })) {
      const r = path.join(dir, e.name);
      if (e.isDirectory()) walk(r);
      else if (r.endsWith('.dart') && r !== rel) {
        const text = fs.readFileSync(path.join(repoRoot, r), 'utf8');
        text.split('\n').forEach((l, i) => {
          if (/nativeController\s*\.\s*(loadUrl|reload|loadData|loadFile)\s*\(/.test(l)) {
            offenders.push(`${r}:${i + 1}`);
          }
        });
      }
    }
  };
  walk('lib');
  assert.deepEqual(offenders, [],
      'route loads through WebViewController so file imports stay covered');
});
