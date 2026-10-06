// Structural gate: every filter-engine entry point normalizes its URLs.
//
// adblock-rust parses the URL itself and never sees `extractHost`'s output, so a
// trailing root dot (`tracker.example.com.`) reaches the engine intact and matches
// no host-anchored rule unless the caller strips it first. The behavioural test
// for this needs the native engine, which is skipped wherever the Rust library is
// not built — so the funnel is asserted structurally here instead, where it runs
// on every platform.

const test = require('node:test');
const assert = require('node:assert');
const { read, methodBody } = require('./helpers/source');

const SERVICE = 'lib/services/content_blocker_service.dart';

// ContentBlockerService methods that hand a URL to the Rust engine.
const ENTRY_POINTS = ['isBlocked', 'redirectFor', 'rewrittenUrl', 'cspFor'];

test('every filter-engine entry point strips the root dot from url and sourceUrl', () => {
  for (const name of ENTRY_POINTS) {
    const body = methodBody(name, { file: SERVICE });

    // Either the argument is wrapped at the call, or the parameter was
    // normalized into a local first — both funnel through stripRootDot.
    assert.ok(
      body.includes('stripRootDot('),
      `${name} does not normalize its URL before the engine sees it`,
    );
    assert.ok(
      !/sourceUrl:\s*sourceUrl\b/.test(body),
      `${name} passes its sourceUrl parameter to the engine unnormalized; ` +
        'route it through stripRootDot(...)',
    );
  }
});

test('the Dart and Kotlin host extractors both drop a single trailing dot', () => {
  const dart = read('lib/services/host_lookup.dart');
  assert.ok(
    dart.includes('stripRootDot'),
    'host_lookup.dart must expose stripRootDot so callers share one normalization',
  );

  const kotlin = read(
    'android/app/src/main/kotlin/org/codeberg/theoden8/webspace/WebInterceptPlugin.kt',
  );
  assert.ok(
    kotlin.includes('stripRootDot'),
    'WebInterceptPlugin.kt must keep its stripRootDot mirror of the Dart helper',
  );
});
