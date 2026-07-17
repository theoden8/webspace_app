# BUG-005 — Per-site User-Agent freezes at a stale snapshot

Status: open

## Symptom

A previously created site keeps sending (and showing in settings) an old
User-Agent long after both the app and the OS moved on — e.g.
`Mozilla/5.0 (iPhone; CPU iPhone OS 18_7 like Mac OS X)
AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148` on a device whose
current default no longer says that. Sites sniff the stale/webview-shaped
string and degrade pages or bounce logins.

## Root mechanism / invariant

A UA persisted as a **rendered string** is a derivative frozen at capture
time; only *intent* survives updates. Two intents exist and each has a
stable representation: "generated Firefox shape" → `uaPreset`
(re-rendered per build/version), and "no override" → empty `userAgent`
(webview sends its live default). Any code path that captures a rendered
string into `userAgent` — a generator writing text, a settings screen
pre-filling the field with the device default and persisting it on save —
silently converts a self-updating intent into a frozen snapshot. The
invariant: **`userAgent` may only hold text the user actually authored;
anything the app rendered or the platform reported must be stored as
intent (preset or empty), never as a string.**
Spec: DM-005 in
[openspec/specs/desktop-mode/spec.md](../../openspec/specs/desktop-mode/spec.md).

Capture paths as of this writing:

- Randomize button → field text → `setUserAgent` (generator output).
- Settings-screen prefill (`getResetUserAgent`, removed) → save
  (platform default output).
- Reset ("home") button pasting `defaultUserAgent` into the field
  (removed).
- Backup import replaying any of the above from an older device.

## Fix attempts

1. **2026-06-25 — PR #410** (`6b31ed4`). Introduced `uaPreset`: generated
   UAs persist as intent and re-render at webview creation from the
   current builders + scraped Firefox version; `fromJson`/`setUserAgent`
   recognize every shape any historical generator emitted (including the
   pre-#410 iPhone-in-Gecko hybrid) and re-attach the preset. *Why
   partial*: only covered generator-emitted strings. The settings screen
   still pre-filled the UA field with `defaultUserAgent` and persisted
   any non-empty field on save, so merely opening and saving site
   settings on a no-override site froze the device default of that day
   as a "custom" string — a shape the recognizer rightly never claims.
   An override also could not be cleared: empty field was skipped on
   save.

2. **2026-07-17 — this branch.** Closed the settings-screen capture path:
   the field shows the platform default only as a hint, save persists the
   field unconditionally (empty clears the override), reset clears
   instead of pasting. Healed already-frozen data:
   `isStockWebViewDefaultUserAgent` recognizes stock
   WKWebView/Android-WebView/WPE default shapes at any OS version and
   `fromJson`/`setUserAgent` drop them back to "no override"; a saved
   string equal to the live `defaultUserAgent` clears the same way. Added
   the DM-006 identity readout so a frozen/webview-shaped UA is visible
   in settings instead of silent. *Known residual*: see gaps.

## Known open gaps

- The stock-default recognizer is a closed list of grammars. If Apple or
  Google change their default UA shape, snapshots of the new shape frozen
  by an old app version won't be recognized on load (the save-time
  equality check against the live default still catches same-device
  captures).
- `fromJson` runs before any webview exists, so it cannot compare against
  the live `defaultUserAgent`; a frozen default that matches no known
  stock shape survives rehydration as custom text. The identity readout
  at least surfaces it.
- A user who deliberately wants to send a stock-default string verbatim
  cannot: it is always normalized to "no override". Considered
  acceptable — the live default is the same string, minus the rot.
