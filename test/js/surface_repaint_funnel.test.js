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
      latch: /_armCommitLatch\(\)/,
      settled: /_surfaceRepaint\.noteLoadSettled\(\)/,
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
    assert.match(src, /_armCommitLatch\(\)/,
      'the reload must be latched on the engine');
    assert.match(src, /_surfaceRepaint\.noteLoadSettled\(\)/,
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

// Route-return repaint gate (PAUSE-024 / BUG-001 Attempt 10). An opaque route
// pushed over a webview screen stops its platform view from being composited,
// so Android detaches the SurfaceView and re-attaches it blank on the pop.
// That pop passes through no other chokepoint — same site, same controller, no
// navigation, no lifecycle event — so every webview-hosting screen must be
// RouteAware and nudge in didPopNext.
{
  test('lib/main.dart: the app registers the surface route observer', () => {
    const src = linesOf('lib/main.dart').join('\n');
    assert.match(src, /navigatorObservers:\s*\[[^\]]*surfaceRouteObserver/,
      'MaterialApp must register surfaceRouteObserver, or no screen is notified');
  });

  for (const rel of GUARDED) {
    const lines = linesOf(rel);
    const src = lines.join('\n');

    test(`${rel}: the webview screen subscribes to the route observer`, () => {
      assert.match(src, /with\s+[^{]*RouteAware/,
        'the state class must mix in RouteAware');
      assert.match(src, /surfaceRouteObserver\.subscribe\(this,\s*route\)/,
        'didChangeDependencies must subscribe the screen to its PageRoute');
      assert.match(src, /surfaceRouteObserver\.unsubscribe\(this\)/,
        'dispose must unsubscribe, or the observer retains a dead State');
    });

    test(`${rel}: didPopNext repaints the re-attached surface (PAUSE-024)`, () => {
      const defIdx = lines.findIndex((l) => /void\s+didPopNext\s*\(/.test(l));
      assert.ok(defIdx >= 0, 'didPopNext override must exist');
      const body = lines.slice(defIdx, defIdx + 8).join('\n');
      assert.match(body, /_nudgeSurfaceRepaint\(\)/,
        'returning from a pushed route must nudge the surface');
    });
  }
}

// First-commit repaint gate (PAUSE-025 / BUG-001 Attempt 10, bug doc gap #7).
// A freshly-attached SurfaceView shows its white default fill until the first
// document commits, which on a slow page lands after the attach nudge's ~0.6s
// budget has drained. The attach must therefore arm the same latch a reload
// does, so the load-settled signal repaints the committed document.
{
  const COMMIT_LATCH = [
    // file, the attach handler that must arm the latch
    { file: 'lib/main.dart', handler: /onControllerReady\s*=\s*\(\)\s*\{/ },
    { file: 'lib/screens/inappbrowser.dart', handler: /onControllerCreated:\s*\(controller\)\s*\{/ },
  ];

  for (const { file, handler } of COMMIT_LATCH) {
    test(`${file}: a fresh controller attach latches the first commit`, () => {
      const lines = linesOf(file);
      const defIdx = lines.findIndex((l) => handler.test(l));
      assert.ok(defIdx >= 0, 'the controller-attach handler must exist');
      const body = lines.slice(defIdx, defIdx + 20).join('\n');
      assert.match(body, /_armCommitLatch\(\)/,
        'the attach must arm the commit latch (PAUSE-025)');
      assert.match(body, /_nudgeSurfaceRepaint\(\)/,
        'the attach must also nudge now (PAUSE-017)');
    });
  }
}

// Nested-screen lifecycle parity (PAUSE-020 in InAppWebViewScreen, BUG-001
// Attempt 10). A warm start re-attaches the nested SurfaceView exactly as it
// does the main page's, and the main page's nudge cannot reach it: that one
// toggles an inset around an IndexedStack sitting under this route.
{
  const lines = linesOf('lib/screens/inappbrowser.dart');
  const src = lines.join('\n');

  test('lib/screens/inappbrowser.dart: a resume repaints the nested surface', () => {
    const defIdx = lines.findIndex((l) =>
      /void\s+didChangeAppLifecycleState\s*\(/.test(l),
    );
    assert.ok(defIdx >= 0, 'the nested screen must observe app lifecycle');
    const body = lines.slice(defIdx, defIdx + 24).join('\n');
    assert.match(body, /_openResumeRepaintWindow\(\)/,
      'a resume must open the post-resume repaint window');
    assert.match(body, /_nudgeSurfaceRepaint\(\)/,
      'a resume must nudge the nested surface');
  });

  test('lib/screens/inappbrowser.dart: didChangeMetrics re-nudges in the window', () => {
    const defIdx = lines.findIndex((l) => /void\s+didChangeMetrics\s*\(/.test(l));
    assert.ok(defIdx >= 0, 'didChangeMetrics override must exist');
    const body = lines.slice(defIdx, defIdx + 12).join('\n');
    assert.match(body, /_resumeRepaintWindowOpen/,
      'the re-nudge must be bounded to the post-resume window');
    assert.match(body, /_nudgeSurfaceRepaint\(\)/,
      'the attach signal must nudge the nested surface');
  });

  test('lib/screens/inappbrowser.dart: the resume window timer is cancelled', () => {
    assert.match(src, /_resumeRepaintWindowTimer\?\.cancel\(\)/,
      'dispose must cancel the window timer');
  });
}

// Bounded commit window (PAUSE-027 / BUG-001 Attempt 11). The commit latch used
// to be one-shot, so the first load that settled after an issue spent it. Two
// refreshes inside one document's lifetime settle twice — the aborted load, then
// the replacement — and the second, which is what the user is looking at, got no
// repaint. Every host that latches a commit must therefore arm through a helper
// that holds the window open for a bounded time and close it on a timer.
{
  const LATCH_HOSTS = ['lib/main.dart', 'lib/screens/inappbrowser.dart'];

  for (const rel of LATCH_HOSTS) {
    const lines = linesOf(rel);
    const src = lines.join('\n');

    test(`${rel}: _armCommitLatch arms the engine and bounds the window`, () => {
      const defIdx = lines.findIndex((l) => /void\s+_armCommitLatch\s*\(\)/.test(l));
      assert.ok(defIdx >= 0, '_armCommitLatch must be defined');
      const body = lines.slice(defIdx, defIdx + 10).join('\n');
      assert.match(body, /_surfaceRepaint\.noteCommitPending\(\)/,
        'the helper must arm the engine latch');
      assert.match(body, /_commitWindowTimer\?\.cancel\(\)/,
        'a new issue must restart the window rather than stack timers');
      assert.match(body, /Timer\(SurfaceRepaintEngine\.commitWindow/,
        'the window must be bounded by the engine-owned duration');
      assert.match(body, /_surfaceRepaint\.closeCommitWindow\(\)/,
        'the timer must close the window (PAUSE-027)');
    });

    test(`${rel}: nothing arms the engine latch outside the helper`, () => {
      const offenders = [];
      lines.forEach((l, i) => {
        if (/^\s*(\/\/|\*)/.test(l)) return; // prose, not a call site
        if (!/_surfaceRepaint\.noteCommitPending\(\)/.test(l)) return;
        if (/void\s+_armCommitLatch\s*\(\)/.test(context(lines, i, 3, 0))) return;
        offenders.push(i + 1);
      });
      assert.deepEqual(offenders, [],
        `raw noteCommitPending() at line(s) ${offenders.join(', ')}; ` +
          'arm through _armCommitLatch so the window is bounded (PAUSE-027).');
    });

    test(`${rel}: dispose cancels the commit window timer`, () => {
      const defIdx = lines.findIndex((l) => /void\s+dispose\s*\(\)/.test(l));
      assert.ok(defIdx >= 0, 'dispose must exist');
      const body = lines.slice(defIdx, defIdx + 14).join('\n');
      assert.match(body, /_commitWindowTimer\?\.cancel\(\)/,
        'a pending window timer must not outlive the screen');
    });

    test(`${rel}: the menu offers a manual repaint (PAUSE-028)`, () => {
      assert.match(src, /value:\s*"repaint"/,
        'the overflow menu must carry a repaint entry');
      assert.match(src, /case\s+'repaint':\s*\n\s*_repaintCurrentSurface\(\);/,
        'selecting it must route to _repaintCurrentSurface');
      const defIdx = lines.findIndex((l) =>
        /void\s+_repaintCurrentSurface\s*\(\)/.test(l),
      );
      assert.ok(defIdx >= 0, '_repaintCurrentSurface must be defined');
      const body = lines.slice(defIdx, defIdx + 12).join('\n');
      assert.match(body, /_nudgeSurfaceRepaint\(\)/,
        'the manual action must actually nudge the surface');
      assert.match(body, /SurfaceDiag/,
        'the manual trigger must be traceable in a shareable log');
    });
  }
}

