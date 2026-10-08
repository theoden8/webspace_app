// Surface-repaint funnel gate (PAUSE-018 / BUG-001). The structural, code-level
// counterpart of formal/kernel.tla's RepaintLiveness: on Android, every back
// navigation of a webview MUST route through a _goBackAndRepaint funnel so the
// hybrid-composition SurfaceView is recomposited after a back/forward-cache
// restore. A new raw controller.goBack() on the Android path would re-open
// BUG-001 (the white screen) — exactly the "unmodeled path" the model can't see
// but a static gate can. Attempts 2–5 in docs/bugs/001-white-screen.md each
// left one such path; this makes a new one fail CI.
//
// Covers the main page, whose back gesture lives in
// lib/controllers/back_gesture_controller.dart, and the nested InAppWebViewScreen
// (lib/screens/inappbrowser.dart) — the latter was BUG-001 gap #1. Both drive
// one SurfaceRepaintController (lib/controllers/surface_repaint_controller.dart),
// so the funnel's own properties are checked there once, and each host is
// checked for wiring its triggers to it.

const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { read, methodBody } = require('./helpers/source');

// Files that host an Android webview back path and so must have the funnel.
const GUARDED = ['lib/screens/webspace_page.dart', 'lib/screens/inappbrowser.dart'];
// Where a screen's overflow menu is built, when not in the screen itself.
const MENU_OF = { 'lib/screens/webspace_page.dart': 'lib/widgets/site_menu.dart' };
// Where a screen's back navigation lives, when not in the screen itself.
const BACK_OF = { 'lib/screens/webspace_page.dart': 'lib/controllers/back_gesture_controller.dart' };
const CONTROLLER = 'lib/controllers/surface_repaint_controller.dart';
const controllerMethod = (name) => methodBody(name, { file: CONTROLLER });

function linesOf(rel) {
  return read(rel).split('\n');
}

// The `before` lines above and `after` lines below line `i`, joined.
function context(lines, i, before, after) {
  return lines.slice(Math.max(0, i - before), i + after + 1).join('\n');
}

for (const screen of GUARDED) {
  const rel = BACK_OF[screen] ?? screen;
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
    assert.match(body, /_surface\.nudge\('back'\)/, 'funnel must nudge the surface');
  });

  test(`${rel}: Android back-nav routes through the funnel`, () => {
    // >= 2: the definition plus at least one call site.
    const refs = (src.match(/_goBackAndRepaint\(/g) || []).length;
    assert.ok(refs >= 2, `expected funnel definition + >=1 call site, found ${refs}`);
  });

  test(`${rel}: no raw controller.goBack() on the Android path (PAUSE-018 gate)`, () => {
    const offenders = [];
    if (rel !== screen) {
      linesOf(screen).forEach((l, i) => {
        if (/\.goBack\(\)/.test(l)) offenders.push(`${screen}:${i + 1}`);
      });
    }
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
      latch: /_surface\.armCommitLatch\(\)/,
      settled: /_surface\.loadSettled\(\)/,
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

  // The page holds no controller of its own — it reloads through the model —
  // so its obligation is to hand every loaded site's hooks to the repaint
  // controller, whose watch wires them to the engine.
  test('the page: reload hooks drive the surface repaint engine', () => {
    const src = linesOf('lib/screens/webspace_page.dart').join('\n');
    assert.match(methodBody('_wireSite'), /_surface\.watch\(site,/,
      'every loaded site must be watched by the repaint controller');
    assert.match(methodBody('_buildBodyWithBottomBar'), /_wireSite\(/,
      'the body must wire each loaded site');
    const watch = methodBody('watch', { file: 'lib/controllers/surface_repaint_controller.dart' });
    const reload = watch.slice(watch.search(/site\.onReloadIssued\s*=/));
    assert.match(reload.slice(0, 200), /armCommitLatch\(\)/,
      'the reload must be latched on the engine');
    assert.match(watch, /site\.onLoadSettled\s*=[^;]*loadSettled\(\)/s,
      'the settled load must re-nudge (PAUSE-021)');
    const offenders = [];
    linesOf('lib/screens/webspace_page.dart').forEach((l, i) => {
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
  const lines = linesOf('lib/screens/webspace_page.dart');
  const src = lines.join('\n');

  test('lib/main.dart: didChangeMetrics re-nudges within the post-resume window', () => {
    const defIdx = lines.findIndex((l) => /void\s+didChangeMetrics\s*\(/.test(l));
    assert.ok(defIdx >= 0, 'didChangeMetrics override must exist');
    const body = lines.slice(defIdx, defIdx + 8).join('\n');
    assert.match(body, /_surface\.metricsChanged\(\)/,
      'didChangeMetrics must hand the attach signal to the repaint controller');
  });

  test('the post-resume repaint window is opened on resume', () => {
    const resumed = methodBody('_foregrounded', { file: 'lib/controllers/app_lifecycle_controller.dart' });
    assert.match(resumed, /surface\.openResumeWindow\(\)/,
      'a resume must open the post-resume repaint window');
  });

  test(`${CONTROLLER}: a metrics change nudges only inside the window`, () => {
    assert.match(controllerMethod('metricsChanged'),
      /if \(_resumeWindowOpen\) nudge\('metrics-resume'\);/,
      'steady-state metric changes (keyboard, rotation) must not nudge');
    assert.match(controllerMethod('openResumeWindow'),
      /Timer\(const Duration\(seconds: 3\)/,
      'the window must close on its own');
  });
}

// Nudge-inset publication gate (ETP-020 x BUG-001). The nudge's body inset is
// not private to the repaint machinery: anything below it that quantises its
// own size amplifies the pixel. The letterbox box is a step function of the
// available height, so a raw inset drops it a whole grid step and the bars
// flash in and out on every toggle. The inset must therefore reach the box, and
// both the Padding and the scope must read the same value — a second, unpublished
// inset would reproduce the jitter.
{
  const lines = linesOf('lib/screens/webspace_page.dart');
  const src = lines.join('\n');

  test('lib/main.dart: the nudge inset is published to SurfaceNudgeScope', () => {
    assert.match(src, /SurfaceNudgeScope\(\s*\n?\s*bottomInset:\s*nudgeInset,/,
      'the body must publish the nudge inset for descendants that quantise size');
    assert.match(src, /final\s+nudgeInset\s*=\s*_surface\.bottomInset;/,
      'the inset must be read once so the Padding and the scope cannot drift');
  });

  test('lib/main.dart: no unpublished nudge inset', () => {
    const offenders = [];
    lines.forEach((l, i) => {
      if (/_surface\.bottomInset/.test(l) && !/final\s+nudgeInset/.test(l)) {
        offenders.push(i + 1);
      }
    });
    assert.deepEqual(offenders, [],
      `raw _surface.bottomInset at line(s) ${offenders.join(', ')}; route it through ` +
        'nudgeInset so SurfaceNudgeScope carries it to the letterbox.');
  });

  test('lib/services/webview.dart: the letterbox backs the nudge out of its snap', () => {
    const wv = linesOf('lib/services/webview.dart');
    const defIdx = wv.findIndex((l) => /Widget\s+_applyLetterbox\s*\(/.test(l));
    assert.ok(defIdx >= 0, '_applyLetterbox must exist');
    const body = wv.slice(defIdx, defIdx + 30).join('\n');
    assert.match(body, /transientInsetHeight:\s*SurfaceNudgeScope\.bottomInsetOf\(context\)/,
      'the box must snap against the settled extent, not the nudged one');
  });
}

// Route-return repaint gate (PAUSE-024 / BUG-001 Attempt 10). An opaque route
// pushed over a webview screen stops its platform view from being composited,
// so Android detaches the SurfaceView and re-attaches it blank on the pop.
// That pop passes through no other chokepoint — same site, same controller, no
// navigation, no lifecycle event — so every webview-hosting screen must be
// RouteAware and nudge in didPopNext.
{
  test('lib/app.dart: the app registers the surface route observer', () => {
    const src = linesOf('lib/app.dart').join('\n');
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
      assert.match(body, /_surface\.nudge\(/,
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
    // file, the attach handler that must arm the latch, how it reaches the controller
    { file: 'lib/controllers/surface_repaint_controller.dart',
      handler: /site\.onControllerReady\s*=\s*\(\)\s*\{/, via: '' },
    { file: 'lib/screens/inappbrowser.dart',
      handler: /onControllerCreated:\s*\(controller\)\s*\{/, via: '_surface.' },
  ];

  for (const { file, handler, via } of COMMIT_LATCH) {
    test(`${file}: a fresh controller attach latches the first commit`, () => {
      const lines = linesOf(file);
      const defIdx = lines.findIndex((l) => handler.test(l));
      assert.ok(defIdx >= 0, 'the controller-attach handler must exist');
      const body = lines.slice(defIdx, defIdx + 20).join('\n');
      assert.ok(body.includes(`${via}armCommitLatch()`),
        'the attach must arm the commit latch (PAUSE-025)');
      assert.ok(body.includes(`${via}nudge(`),
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
    assert.match(body, /_surface\.openResumeWindow\(\)/,
      'a resume must open the post-resume repaint window');
    assert.match(body, /_surface\.nudge\(/,
      'a resume must nudge the nested surface');
  });

  test('lib/screens/inappbrowser.dart: didChangeMetrics re-nudges in the window', () => {
    const defIdx = lines.findIndex((l) => /void\s+didChangeMetrics\s*\(/.test(l));
    assert.ok(defIdx >= 0, 'didChangeMetrics override must exist');
    const body = lines.slice(defIdx, defIdx + 6).join('\n');
    assert.match(body, /_surface\.metricsChanged\(\)/,
      "the attach signal must reach the nested surface's controller");
  });
}

// Bounded commit window (PAUSE-027 / BUG-001 Attempt 11). The commit latch used
// to be one-shot, so the first load that settled after an issue spent it. Two
// refreshes inside one document's lifetime settle twice — the aborted load, then
// the replacement — and the second, which is what the user is looking at, got no
// repaint. Every host that latches a commit must therefore arm through a helper
// that holds the window open for a bounded time and close it on a timer.
{
  test(`${CONTROLLER}: armCommitLatch arms the engine and bounds the window`, () => {
    const body = controllerMethod('armCommitLatch');
    assert.match(body, /_engine\.noteCommitPending\(\)/,
      'the helper must arm the engine latch');
    assert.match(body, /_commitWindowTimer\?\.cancel\(\)/,
      'a new issue must restart the window rather than stack timers');
    assert.match(body, /Timer\(SurfaceRepaintEngine\.commitWindow/,
      'the window must be bounded by the engine-owned duration');
    assert.match(body, /_engine\.closeCommitWindow\(\)/,
      'the timer must close the window (PAUSE-027)');
    // The engine is private to the controller, so no host can arm it raw.
    assert.equal((read(CONTROLLER).match(/_engine\.noteCommitPending\(\)/g) || []).length, 1,
      'only armCommitLatch arms the latch, so the window is always bounded');
  });

  test(`${CONTROLLER}: dispose cancels every timer`, () => {
    const body = controllerMethod('dispose');
    for (const timer of ['_commitWindowTimer', '_logFlushTimer', '_resumeWindowTimer']) {
      assert.ok(body.includes(`${timer}?.cancel()`), `${timer} must not outlive the screen`);
    }
  });

  for (const rel of GUARDED) {
    const lines = linesOf(rel);
    const src = lines.join('\n');

    test(`${rel}: dispose disposes the repaint controller`, () => {
      const defIdx = lines.findIndex((l) => /void\s+dispose\s*\(\)/.test(l));
      assert.ok(defIdx >= 0, 'dispose must exist');
      const body = lines.slice(defIdx, defIdx + 14).join('\n');
      assert.match(body, /_surface\.dispose\(\)/,
        'a pending window timer must not outlive the screen');
    });

    test(`${rel}: the menu offers a manual repaint (PAUSE-028)`, () => {
      // Both menus are typed: each decides an action's entry in one switch
      // arm (`SiteMenuAction` in its widget, `_NestedMenuAction` here).
      const menu = MENU_OF[rel] ? read(MENU_OF[rel]) : src;
      const entry = /\w+MenuAction\.repaint\s*=>/g;
      assert.match(menu, entry, 'the overflow menu must carry a repaint entry');
      // The entry is a diagnostic, not a feature: EVERY occurrence must sit
      // behind the developer-mode gate as well as the Android one, or a user
      // meets a button whose effect they cannot interpret. Counted, not
      // matched: a file with two menus must not pass on one gated entry.
      const entries = (menu.match(entry) || []).length;
      const gated = (
        menu.match(
          /\w+MenuAction\.repaint\s*=>\s*hostIsAndroid\s*&&\s*DeveloperModeService\.instance\.enabled\s*\?/g,
        ) || []
      ).length;
      assert.equal(gated, entries,
        `${entries} repaint entr(y|ies), ${gated} behind the developer-mode ` +
          'gate; every one must be (PAUSE-028).');
      assert.match(src,
        /case\s+\w+MenuAction\.repaint:\s*\n\s*_repaintCurrentSurface\(\);/,
        'selecting it must route to _repaintCurrentSurface');
      const body = methodBody('_repaintCurrentSurface', { file: rel });
      // A mechanism that does not route through the nudge funnel emits no
      // trigger= line, so the controller names each one as it hands it out.
      if (/nextManual\(\)/.test(body)) {
        assert.match(controllerMethod('nextManual'), /LogTag\.surfaceDiag\./,
          'a branching manual repaint must log which mechanism it ran');
      }
      assert.match(body, /_surface\.nudge\('manual'\)/,
        "the manual action must nudge under the 'manual' trigger, so a user " +
          'report can be matched to the log line the tap produced');
    });
  }
}

// Commit-visible trigger (BUG-001 Attempt 12 / PAUSE-031). `onPageCommitVisible`
// is the only signal that fires because the renderer produced pixels; every
// other trigger is a lifecycle event hoped to imply one. Gap #18 caught a load
// whose nudges had all drained, and whose 15s commit window had closed, before
// the renderer produced anything. So this trigger must NOT be gated on that
// window -- a later tidy-up that routes it through noteLoadSettled() would
// reproduce exactly the failure it was added for.
{
  const GUARDED = [
    // file, the commit-visible nudge as that file calls it
    { rel: 'lib/controllers/surface_repaint_controller.dart', call: "nudge('page-commit-visible')" },
    { rel: 'lib/screens/inappbrowser.dart', call: "_surface.nudge('page-commit-visible')" },
  ];
  for (const { rel, call } of GUARDED) {
    const lines = linesOf(rel);
    const src = lines.join('\n');

    test(`${rel}: the commit-visible trigger nudges (PAUSE-031)`, () => {
      assert.ok(src.includes(call),
        'onPageCommitVisible must route through the nudge funnel');
    });

    test(`${rel}: the commit-visible trigger is not window-gated (PAUSE-031)`, () => {
      const i = lines.findIndex((l) => l.includes(call));
      assert.ok(i >= 0, 'the commit-visible nudge must exist');
      // The five lines above the nudge: enough to hold an index guard, not
      // enough to reach the neighbouring commit-settled handler's own gate.
      const before = lines.slice(Math.max(0, i - 5), i).join('\n');
      assert.doesNotMatch(before, /loadSettled\(\)/,
        'the commit-visible nudge must not be gated on the commit window: ' +
          'the window can close before a slow renderer produces a frame');
    });
  }
}

// Diagnostic funnel (BUG-001 Attempt 11). The SurfaceDiag trace exists to say
// WHICH path repainted on a device that went blank, and hand-written log lines
// at a few call sites left most paths dark: 6 of 26 nudges reported. The line
// is therefore emitted inside the controller's nudge from its trigger, which
// the compiler makes every call site pass.
{
  test(`${CONTROLLER}: the nudge funnel reports its own trigger`, () => {
    assert.match(controllerMethod('nudge'), /_trace\(trigger,\s*coalesced:/,
      'the funnel must report through _trace, not its call sites');
  });

  test(`${CONTROLLER}: the trace is gated on developer mode and throttled`, () => {
    const body = controllerMethod('_trace');
    // A repaint line per call would evict LogService's 2000-entry ring with
    // one repeated sentence: didChangeMetrics alone fires it many times a
    // second through a warm resume.
    assert.match(body, /if\s*\(!DeveloperModeService\.instance\.enabled\)\s*return;/,
      'an ordinary session must not spend its log ring on the repaint trace');
    assert.match(body, /_log\.note\(/,
      'the trace must go through the burst collapser');
    assert.match(body, /RepaintLogThrottle\.burstWindow/,
      'a folded burst must be flushed on the throttle window');
    assert.match(body, /_log\.flush\(\)/,
      'the flush timer must emit the pending summary');
  });

  for (const rel of GUARDED) {
    const src = linesOf(rel).join('\n');

    test(`${rel}: no call site hand-writes a trigger line any more`, () => {
      // A duplicate line at a call site is how the coverage drifted before:
      // the funnel reports, so a second report means someone re-introduced the
      // per-site pattern and the next path will be forgotten again.
      const hand = (src.match(/'trigger=[a-z-]+ -> nudge/g) || []).length;
      assert.equal(hand, 0,
        'trigger lines belong in the funnel, not at the call sites');
    });
  }
}
