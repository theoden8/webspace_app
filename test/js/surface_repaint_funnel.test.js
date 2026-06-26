// Surface-repaint funnel gate (PAUSE-018 / BUG-001). The structural, code-level
// counterpart of formal/kernel.tla's RepaintLiveness: on Android, every back
// navigation of a webview MUST route through a _goBackAndRepaint funnel so the
// hybrid-composition SurfaceView is recomposited after a back/forward-cache
// restore. A new raw controller.goBack() on the Android path would re-open
// BUG-001 (the white screen) — exactly the "unmodeled path" the model can't see
// but a static gate can. Attempts 2–5 in docs/bugs/001-white-screen.md each
// left one such path; this makes a new one fail CI.
//
// Covers the main page (lib/main.dart) and the nested InAppWebViewScreen
// (lib/screens/inappbrowser.dart) — the latter was BUG-001 gap #1.

const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const repoRoot = path.resolve(__dirname, '..', '..');

// Files that host an Android webview back path and so must have the funnel.
const GUARDED = ['lib/main.dart', 'lib/screens/inappbrowser.dart'];

function linesOf(rel) {
  return fs.readFileSync(path.join(repoRoot, rel), 'utf8').split('\n');
}

for (const rel of GUARDED) {
  const lines = linesOf(rel);
  const src = lines.join('\n');
  const near = (i, b, a) =>
    lines.slice(Math.max(0, i - b), i + a + 1).join('\n');

  test(`${rel}: _goBackAndRepaint funnel exists and recomposites the surface`, () => {
    const defIdx = lines.findIndex((l) =>
      /Future<void>\s+_goBackAndRepaint\s*\(/.test(l),
    );
    assert.ok(defIdx >= 0, '_goBackAndRepaint must be defined');
    const body = lines.slice(defIdx, defIdx + 6).join('\n');
    assert.match(body, /controller\.goBack\(\)/, 'funnel must call goBack');
    assert.match(body, /_nudgeSurfaceRepaint\(\)/, 'funnel must nudge the surface');
  });

  test(`${rel}: Android back-nav routes through the funnel`, () => {
    // >= 2: the definition plus at least one call site.
    const refs = (src.match(/_goBackAndRepaint\(/g) || []).length;
    assert.ok(refs >= 2, `expected funnel definition + >=1 call site, found ${refs}`);
  });

  test(`${rel}: no raw controller.goBack() on the Android path (PAUSE-018 gate)`, () => {
    const offenders = [];
    lines.forEach((l, i) => {
      if (!/controller\.goBack\(\)/.test(l)) return;
      // Exempt the funnel definition itself (goBack sits 1–3 lines under the sig).
      const isFunnel = /_goBackAndRepaint\s*\(/.test(near(i, 4, 0));
      // Exempt the iOS/macOS path: it uses URL comparison and has no SurfaceView
      // to recomposite, so it deliberately does not nudge.
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
}
