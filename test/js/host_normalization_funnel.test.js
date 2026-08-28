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
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (p) => fs.readFileSync(path.join(ROOT, p), 'utf8');

// ContentBlockerService methods that hand a URL to the Rust engine.
const ENTRY_POINTS = ['isBlocked', 'redirectFor', 'rewrittenUrl', 'cspFor'];

/** Body of the `name(...)` declaration, brace-matched. Anchored on a
 *  two-space-indented return type so a call site cannot be mistaken for it. */
function methodBody(src, name) {
  const decl = new RegExp(`^  [\\w<>?,\\[\\] ]+\\s${name}\\s*\\(`, 'm').exec(src);
  assert.ok(decl, `${name} declaration not found in content_blocker_service.dart`);

  // Step over the parameter list first: Dart named/optional parameters are
  // themselves brace-delimited, so the first `{` after the declaration is not
  // the body.
  const lparen = src.indexOf('(', decl.index);
  let parens = 0;
  let afterParams = -1;
  for (let i = lparen; i < src.length; i++) {
    if (src[i] === '(') parens++;
    else if (src[i] === ')') {
      parens--;
      if (parens === 0) {
        afterParams = i + 1;
        break;
      }
    }
  }
  assert.ok(afterParams !== -1, `${name} has an unbalanced parameter list`);

  const open = src.indexOf('{', afterParams);
  assert.ok(open !== -1, `${name} has no body`);
  let depth = 0;
  for (let i = open; i < src.length; i++) {
    if (src[i] === '{') depth++;
    else if (src[i] === '}') {
      depth--;
      if (depth === 0) return src.slice(open, i + 1);
    }
  }
  throw new Error(`unbalanced braces in ${name}`);
}

test('every filter-engine entry point strips the root dot from url and sourceUrl', () => {
  const src = read('lib/services/content_blocker_service.dart');

  for (const name of ENTRY_POINTS) {
    const body = methodBody(src, name);

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
