# BUG-013 — A captcha loads, spins on "Verifying…", and never resolves

Status: open (each attempt so far fixed the path it was looking at; nothing has
yet made a challenge's *storage and fingerprint* posture match what the site's
own vendor expects)

**Spec:** [openspec/specs/captcha-support/spec.md](../../openspec/specs/captcha-support/spec.md)
— `CAPTCHA-001`…`CAPTCHA-010`. Related:
[tracking-protection](../../openspec/specs/tracking-protection/spec.md) (the
anti-fingerprinting shim and the third-party-cookie force-off),
[worker-shim-propagation](../../openspec/specs/worker-shim-propagation/spec.md)
(`WORK-006`), [nested-url-blocking](../../openspec/specs/nested-url-blocking/spec.md).

## Symptom

A Cloudflare Turnstile widget (or a full-page Cloudflare interstitial, hCaptcha,
reCAPTCHA) renders correctly inside the site's webview, starts its check, and
then sits on "Verifying…" forever. No error, no timeout, no fallback to an
interactive challenge. The same URL, on the same device and network, passes in
Chrome, Brave and Hermit.

The tell, in the developer console:

```
Uncaught SecurityError: Failed to read the 'cookie' property from 'Document':
Access is denied for this document.
```

repeated, followed by knock-on `TypeError`s from the challenge's own code
(`Cannot read properties of null (reading 'appendChild')`) as it continues past
a step that did not complete.

## Root mechanism / invariant

A captcha is a **third-party document the site deliberately embeds and then
waits on**. It is served from `challenges.cloudflare.com` / `hcaptcha.com` /
`google.com`, it runs in an iframe inside the site's page, and the parent page's
form stays disabled until the widget posts a token back. Three things follow,
and every fix attempt below has stepped on one of them:

1. **It is cross-site, so every per-site restriction the app applies to
   "third-party content" applies to it.** Blocking third-party cookies blocks
   the challenge's own storage — chromium refuses `document.cookie` in that
   frame with a `SecurityError`, which is the console line above. The frame is
   not a tracker the user chose to lose; it is the gate they are trying to pass.
2. **It fingerprints the environment on purpose, and compares.** Canvas, WebGL,
   audio, hardware, timing, and the page-versus-worker agreement are all inputs.
   Per-call seeded noise is not a stable-but-wrong fingerprint; it is an
   *inconsistent* one, which is the signal anti-bot vendors are built to catch.
3. **It fails silently by design.** A challenge that decides it is being lied to
   does not throw — it withholds the token. So every breakage in this class
   presents identically, as an indefinite "Verifying…", and none of it reaches
   an error handler, a test assertion, or a crash report.

The invariant: **a captcha frame must see the storage and the environment the
site's vendor would see in a stock browser.** Any per-site restriction the app
applies by origin — cookie policy, fingerprint noise, shim indirection,
sub-resource interception — must either exempt the challenge or be something the
user can turn off for that site *and find*.

What makes it recur: each attempt has fixed a **navigation/plumbing** path (can
the URL load, can the popup open, is the popup the right site) while the failure
has moved to a **posture** path (what the frame is allowed to store, what the
environment reports). The two are fixed in different files by different changes,
and the symptom is the same spinner either way.

## Fix attempts

### 1. 2026-01-29 — [#73](https://github.com/theoden8/webspace_app/pull/73) `701e5a6` — enable what the challenge needs to load

**What it did:** turned on `supportMultipleWindows`,
`javaScriptCanOpenWindowsAutomatically`, `domStorageEnabled`, `databaseEnabled`,
`allowFileAccess`, `allowContentAccess`; allowed `about:blank` / `about:srcdoc`
through `_shouldBlockUrl` and through the nested-navigation domain check; added
`onCreateWindow` popup creation for challenge windows. Wrote
`CAPTCHA-001`…`CAPTCHA-006`.

**Why:** the challenge could not render at all — its iframes were being blocked
as `about:` URLs and its popup verification flow had nowhere to open.

**Why it was partial:** it made the challenge *load*. Every requirement it wrote
is about the webview's own settings, and none of them is about what the loaded
frame may then store or read. The spec's own "Known Limitations" section
attributed the remaining stalls to cross-origin frame access under SOP, which is
a normal, handled condition in every captcha vendor's code and was never the
cause. That misattribution is why the next four years of attempts all looked at
navigation instead of storage.

### 2. 2026-02-16 — [#93](https://github.com/theoden8/webspace_app/pull/93) `774ad14` — narrow the popup allow to Cloudflare

**What it did:** restricted `onCreateWindow` popup creation to recognized
challenge URLs instead of any `window.open()`.

**Why:** the blanket allow from #73 let any page open a popup webview.

**Why it was partial:** a tightening of #73's path, in #73's terms. Same blind
spot.

### 3. 2026-02-18 — [#97](https://github.com/theoden8/webspace_app/pull/97) `d31e9e3` — classify on the parsed host

**What it did:** replaced substring matching on the whole URL with a parsed-host
check.

**Why:** `url.contains('challenges.cloudflare.com')` matched any URL that merely
mentioned the string.

**Why it was partial:** correctness of the *classifier*. A correctly classified
challenge still stalls if the frame cannot keep a cookie.

### 4. 2026-09-10 — [#593](https://github.com/theoden8/webspace_app/pull/593) `db47ddd` — scope the claim to the site (CAPTCHA-007/008/009/010)

**What it did:** made the two host-agnostic Cloudflare path markers count only
on the site's own domain, ordered the captcha allow *after* the navigation
verdict in both interception paths, gave the verification popup its own
`shouldOverrideUrlLoading`, and made the popup inherit the requesting site's
full `WebViewConfig`.

**Why:** a captcha-shaped URL was a bypass of the navigation decision engine —
any origin could claim one and steer the parent webview.

**Why it was partial:** it closed a security hole in the captcha path and
changed nothing about the posture the challenge runs under. `CAPTCHA-009` in
fact *guarantees* the popup inherits the site's posture, which is correct for
identity and containers and means the popup inherits the cookie policy and the
fingerprint noise too.

### 5. 2026-09-16 — this branch — stop installing the worker wrapper on sites with nothing to propagate

**What it did:** `webview.dart` fed the location shim into `workerScopeShims`
unconditionally, so `buildWorkerShimScript` was non-null for every site and
every document got the `Worker`/`SharedWorker` blob indirection. Only the
timezone half of that shim survives worker scope (geolocation is absent from
`WorkerNavigator`, WebRTC is gated on `!IS_WORKER`), so a site with no timezone
override was paying the indirection for an inert payload. Gated the propagation
on `LocationSpoofService.affectsWorkerScope`.

**Why:** `WORK-006` requires the patch to install "only when at least one shim
is active, so a site with no spoofing keeps the stock constructors and cannot be
broken by the blob indirection". The assembly had silently made that
unsatisfiable. The failure mode is on record in the same spec: under a CSP whose
`worker-src` omits `blob:`, the first worker of a document is refused
asynchronously — messenger.com's chat worker died that way and "verifying your
PIN" hung with no error, which is this bug's symptom in another vendor's words.

**Why it is partial:** it removes one always-on deviation from stock browser
behavior on default sites. It does not address the cookie `SecurityError` the
console actually reports, which is the third-party-cookie block, nor the
fingerprint noise. A site that *does* set a timezone override still gets the
wrapper, correctly.

## Known open gaps

1. **Third-party cookies are off by default and unreachable under Tracking
   Protection.** `WebViewModel.thirdPartyCookiesEnabled` defaults to `false`,
   and `effectiveThirdPartyCookiesEnabled` returns `false` unconditionally while
   `trackingProtectionEnabled` is on. So the setting that fixes this is off for
   every new site, and a user who has ETP on cannot turn it on for the one site
   that needs it — the toggle is overridden, not merely defaulted. Chrome, Brave
   and Hermit all allow third-party cookies here; Brave ships an explicit
   storage exception for Cloudflare challenge frames for exactly this reason.
   Nothing in the app connects the observed failure (a spinner) to the setting
   (`Site settings → Privacy → Third-party cookies`), and its hint text — "turn
   them back on for a site that breaks without them" — is only read by someone
   who already suspects cookies.

2. **Tracking Protection is a pincer.** With ETP on, the anti-fingerprinting
   shim salts Canvas/WebGL/audio readbacks *per call site*, so two reads of the
   same surface in one page disagree; that inconsistency is a stronger bot
   signal than any single spoofed value, and third-party cookies are forced off
   on top of it. With ETP off, the cookie block persists (the per-site default
   is still off) and `requestedWithHeaderOriginAllowList` reverts to the
   platform default. Neither position is one a captcha vendor expects, which is
   why toggling ETP changes nothing for the user.

3. **A blocked sub-resource resolves as an empty 200, not a network error.**
   `FastSubresourceInterceptor.checkUrl` returns
   `WebResourceResponse("text/plain", "utf-8", <empty>)` for a DNS or ABP block.
   A challenge step that `fetch`es a blocked URL therefore gets a successful
   response with an unparseable body rather than a rejection, and JS that
   branches on `catch` never runs. Whether any list blocks a challenge host
   today is unverified; the failure *shape* is a silent stall either way.

4. **No HTTPS upgrade.** Unrelated to the challenge itself but reported
   alongside it: chromium's HTTPS-Upgrades (Chrome 115+) silently retries a
   plain-http navigation over https and falls back on failure. Android WebView
   does not ship it and the app does not implement it, so an `http://` URL that
   enters the app from any source stays `http://` when the origin serves both
   schemes without a redirect or HSTS. See `tivipanel.net`.

5. **The whole class is untestable from here.** Every tier the repo has — Dart
   unit, jsdom, Puppeteer, integration — can assert what the app *injects and
   allows*. None of them can assert what Cloudflare *concludes*, because the
   verdict is a server-side judgement over a fingerprint. A regression in this
   class will always be reported by a user, never by CI, which is the argument
   for keeping this file rather than trusting the per-fix scenarios.
