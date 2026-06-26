// Surface-repaint funnel gate (PAUSE-018 / BUG-001). The structural, code-level
// counterpart of formal/kernel.tla's RepaintLiveness: on Android, every back
// navigation of the visible webview MUST route through _goBackAndRepaint so the
// hybrid-composition SurfaceView is recomposited after a back/forward-cache
// restore. A new raw controller.goBack() on the Android path would re-open
// BUG-001 (the white screen) — exactly the "unmodeled path" the model can't see
// but a static gate can. Attempts 2–5 in docs/bugs/001-white-screen.md each
// left one such path; this makes a new one fail CI.
//
// Known gap (BUG-001 gap #1): the nested InAppWebViewScreen
// (lib/screens/inappbrowser.dart) has no nudge mechanism and still calls
// controller.goBack() raw. Tracked in docs/bugs/001-white-screen.md; out of
// scope for this main-page gate.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');
const lines = fs
  .readFileSync(path.join(repoRoot, 'lib/main.dart'), 'utf8')
  .split('\n');
const src = lines.join('\n');

function near(i, before, after) {
  return lines.slice(Math.max(0, i - before), i + after + 1).join('\n');
}

test('the _goBackAndRepaint funnel exists and recomposites the surface', () => {
  const defIdx = lines.findIndex(
    (l) => /Future<void>\s+_goBackAndRepaint\s*\(/.test(l),
  );
  assert.ok(defIdx >= 0, '_goBackAndRepaint must be defined');
  const body = lines.slice(defIdx, defIdx + 6).join('\n');
  assert.match(body, /controller\.goBack\(\)/, 'funnel must call goBack');
  assert.match(body, /_nudgeSurfaceRepaint\(\)/, 'funnel must nudge the surface');
});

test('Android back-nav call sites route through the funnel', () => {
  // 1 definition + >=3 call sites (back gesture + two AppBar back buttons).
  const refs = (src.match(/_goBackAndRepaint\(/g) || []).length;
  assert.ok(refs >= 4, `expected funnel definition + >=3 call sites, found ${refs}`);
});

test('no raw controller.goBack() on the Android path (PAUSE-018 gate)', () => {
  const offenders = [];
  lines.forEach((l, i) => {
    if (!/controller\.goBack\(\)/.test(l)) return;
    // Exempt the funnel definition itself (goBack sits 1–3 lines under the sig).
    const isFunnel = /_goBackAndRepaint\s*\(/.test(near(i, 4, 0));
    // Exempt the iOS/macOS gesture path: it uses URL comparison and has no
    // SurfaceView to recomposite, so it deliberately does not nudge.
    const isIosPath = /urlBefore|urlAfter/.test(near(i, 25, 3));
    if (!isFunnel && !isIosPath) offenders.push(i + 1);
  });
  assert.deepEqual(
    offenders,
    [],
    `raw controller.goBack() outside the funnel at line(s) ${offenders.join(', ')}. ` +
      'On Android, route back navigation through _goBackAndRepaint ' +
      '(PAUSE-018 / BUG-001); the iOS/macOS path is exempt.',
  );
});
