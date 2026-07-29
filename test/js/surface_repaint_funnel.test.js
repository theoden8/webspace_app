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

// The `before` lines above and `after` lines below line `i`, joined.
function context(lines, i, before, after) {
  return lines.slice(Math.max(0, i - before), i + after + 1).join('\n');
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

// Reload repaint gate (PAUSE-021 / BUG-001 Attempt 9). A reload discards the
// painted frame and recommits it an unbounded time later, so the Android
// SurfaceView sits blank in between with nothing to relayout it. Every reload
// of a webview MUST go through a funnel that latches the reload and nudges,
// and the paired load-settled signal MUST re-nudge — the issue-time nudge
// alone drains before a slow page recommits (proved in
// test/surface_repaint_engine_test.dart).
{
  // Reload funnels, per file: name -> the raw call it must wrap.
  const RELOAD_FUNNELS = [
    {
      file: 'lib/web_view_model.dart',
      funnel: /Future<void>\s+reloadAndRepaint\s*\(/,
      latch: /onReloadIssued\?\.call\(\)/,
      settled: /onLoadSettled\?\.call\(\)/,
    },
    {
      file: 'lib/screens/inappbrowser.dart',
      funnel: /Future<void>\s+_reloadAndRepaint\s*\(/,
      latch: /_surfaceRepaint\.reloadIssued\(\)/,
      settled: /_surfaceRepaint\.consumeLoadSettled\(\)/,
    },
  ];

  for (const { file, funnel, latch, settled } of RELOAD_FUNNELS) {
    const lines = linesOf(file);
    const src = lines.join('\n');

    test(`${file}: the reload funnel latches the reload and repaints`, () => {
      const defIdx = lines.findIndex((l) => funnel.test(l));
      assert.ok(defIdx >= 0, 'a reload funnel must be defined');
      const body = lines.slice(defIdx, defIdx + 14).join('\n');
      assert.match(body, /\.reload\(\)/, 'funnel must issue the reload');
      assert.match(body, latch, 'funnel must latch the reload for the settled re-nudge');
    });

    test(`${file}: a settled load repaints the recommitted surface`, () => {
      assert.match(src, settled,
        'the load-settled signal must drive the reload repaint (PAUSE-021)');
    });

    test(`${file}: no raw reload() outside the funnel (PAUSE-021 gate)`, () => {
      const offenders = [];
      lines.forEach((l, i) => {
        if (/^\s*(\/\/|\*)/.test(l)) return; // prose, not a call site
        if (!/(?:controller|ctrl|_controller)[!?]?\.reload\(\)/.test(l)) return;
        // Exempt the funnel definition itself (reload sits a few lines under
        // the signature, past the null check and the latch call).
        if (funnel.test(context(lines, i, 14, 0))) return;
        offenders.push(i + 1);
      });
      assert.deepEqual(
        offenders,
        [],
        `raw reload() outside the funnel at line(s) ${offenders.join(', ')}. ` +
          'Route reloads through the reloadAndRepaint funnel (PAUSE-021 / BUG-001).',
      );
    });
  }

  // main.dart holds no controller of its own — it reloads through the model —
  // so its obligation is to wire the two host hooks to the engine.
  test('lib/main.dart: reload hooks drive the surface repaint engine', () => {
    const src = linesOf('lib/main.dart').join('\n');
    assert.match(src, /onReloadIssued\s*=\s*\(\)\s*\{/,
      'main.dart must handle onReloadIssued for the visible site');
    assert.match(src, /_surfaceRepaint\.reloadIssued\(\)/,
      'the reload must be latched on the engine');
    assert.match(src, /_surfaceRepaint\.consumeLoadSettled\(\)/,
      'the settled load must re-nudge (PAUSE-021)');
    const offenders = [];
    linesOf('lib/main.dart').forEach((l, i) => {
      if (/\.controller\?\.reload\(\)/.test(l)) offenders.push(i + 1);
    });
    assert.deepEqual(offenders, [],
      `raw controller reload in main.dart at line(s) ${offenders.join(', ')}; ` +
        'call WebViewModel.reloadAndRepaint instead.');
  });
}

// Warm-start repaint gate (PAUSE-020 / BUG-001 Attempt 8). The kernel's magic
// WF(Nudge) hid the warm-start ordering (bug doc gap #4): the resume nudge is a
// one-shot that can fire before the async SurfaceView reattach. The fix re-fires
// the nudge on didChangeMetrics — the attach signal — inside a bounded
// post-resume window. This gate keeps that wiring from being silently dropped;
// its ordering is proved in formal/warmstart.tla and test/surface_repaint_engine_test.dart.
{
  const lines = linesOf('lib/main.dart');
  const src = lines.join('\n');

  test('lib/main.dart: didChangeMetrics re-nudges within the post-resume window', () => {
    const defIdx = lines.findIndex((l) => /void\s+didChangeMetrics\s*\(/.test(l));
    assert.ok(defIdx >= 0, 'didChangeMetrics override must exist');
    const body = lines.slice(defIdx, defIdx + 20).join('\n');
    assert.match(body, /_resumeRepaintWindowOpen/,
      'didChangeMetrics must gate on the post-resume window');
    assert.match(body, /_nudgeSurfaceRepaint\(\)/,
      'didChangeMetrics must nudge the surface on the attach signal');
  });

  test('lib/main.dart: the post-resume repaint window is opened on resume', () => {
    assert.match(src, /_openResumeRepaintWindow\(\)/,
      'a resume must open the post-resume repaint window');
    // >= 2: the definition plus at least one call site on the resume path.
    const refs = (src.match(/_openResumeRepaintWindow\(/g) || []).length;
    assert.ok(refs >= 2, `expected window-open definition + >=1 call site, found ${refs}`);
  });
}
