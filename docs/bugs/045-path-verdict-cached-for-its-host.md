# BUG-045: One URL's verdict is cached for its whole host

Status: open

**Spec:** [content-blocker](../../openspec/specs/content-blocker/spec.md) CB-003, CB-012
**Tests:** [test/js/block_interceptor_shim.test.js](../../test/js/block_interceptor_shim.test.js),
[test/browser/block_accounting_real_engine.test.js](../../test/browser/block_accounting_real_engine.test.js),
[integration_test/block_accounting_test.dart](../../integration_test/block_accounting_test.dart)

## Symptom

On iOS, macOS and Linux a path rule's block, or an allow, given for one URL
answers every later request to the same host from the page interceptor's
host cache. A first-party tracker rule (`/ads/*`) that matched once blocked
the site's own API calls; an allow let the next request a path rule names go
out unasked, so the content rule lists stopped it and nothing counted it.

## Root mechanism / invariant

`block_js_interceptor.js` caches a verdict by host (`cachePut`) so a repeat
skips the bridge. The invariant is that only a verdict that is the host's is
cached: a block of a host the lists name, or an allow where no hostless
(path) rule is loaded. Whether a verdict is the host's is decided as the ask
is made (`pendingCacheable`) and applied when the reply settles, so every
state the page can be in at those two points (bloom not yet landed, host
Bloom hit, token hit) must decide it.

## Fix attempts

1. **2026-06-25, #446 (`3fcc1b55`).** Token-driven asks were marked not
   cacheable, and the allows cached while the bloom was loading were dropped
   when it landed with path rules. *Why:* path rules were new to the
   prefilter, and an allow cached by host skipped them. *Why partial:* a
   warm-up ask stayed cacheable. A block a path rule gave during warm-up
   cached its host as blocked (macOS lost `/ok/data` in the block accounting
   test), and an allow whose reply settled after the bloom landed was cached
   after the drop had run (Linux let three blocked fetches out uncounted). A
   host Bloom hit stayed cacheable whatever the verdict, so an allow there
   also skipped the path rules.
2. **2026-11-06, PR #914.** A warm-up ask is not cacheable, and an allow is
   cached only when no path rule is loaded; the drop on landing went with
   the state it cleaned up. The ground-truth integration test found it on
   both WebKit tiers, a real-Chromium replay of its page reproduces each
   order (the bloom landing before the first request and after the first
   few), and each case has a jsdom test that fails without its condition.
   *Why partial:* see below.

## Known open gaps

- A block on a host Bloom hit is still cached by host. A host the lists name
  is blocked whatever the path, but a Bloom false positive whose URL a path
  rule blocks caches its host as blocked. The reply would have to say
  whether the verdict was the host's to close it.
