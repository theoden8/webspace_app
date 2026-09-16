# HTTPS upgrade

## Why

A user reported `https://tivipanel.net/reseller/login.php` showing as
`http://` in the URL bar after loading, where Hermit kept it on https. The
origin answers `200` on both schemes, sends no redirect and sets no HSTS, so
nothing on the server side ever corrects a plain-http entry. Its session cookie
comes back without `Secure`, which means the reseller login rides in cleartext
for as long as the URL stays http.

Nothing in the app rewrote that scheme. `ensureUrlScheme` has always defaulted
typed input to https, ClearURLs preserves the scheme, and the URL bar prints
`currentUrl` verbatim. The gap is that the app has no opinion at all about a
plain-http *navigation*: whatever enters, from a typed host, an old entry, a
link on the page or a server redirect, is what loads.

Chromium has shipped HTTPS-Upgrades since Chrome 115 and applies it to ordinary
navigations by default, with a silent fallback when https does not answer.
Android WebView does not carry that behaviour, so every WebView-based app has to
implement it or go without. That is the whole difference the reporter observed
between Chrome, Brave, Hermit and this app.

This is also the one item in [BUG-013](../../../docs/bugs/013-captcha-verification-stalls.md)
that is not about captchas: gap 5, recorded there because it arrived with the
same report.

## What Changes

- **A new `https-upgrade` capability.** `HttpsUpgradeEngine`
  (`lib/services/https_upgrade_engine.dart`), a pure decision engine: given a
  main-frame URL it returns the https form to try, and given a failed upgrade
  it returns the http form to fall back to, remembering the host so the next
  navigation does not pay the timeout again.
- **Upgrade with silent fallback, not HTTPS-Only.** A failed upgrade loads the
  original http URL. No interstitial, no blocked page, no prompt. An app that
  breaks a LAN device or an intranet page to make a point about TLS gets turned
  off, and then protects nothing.
- **A global knob, default ON.** `httpsUpgradeEnabled` in `kExportedAppPrefs`,
  defaulting to `true`, with a per-site `WebViewModel.httpsUpgradeEnabled`
  override for the site that genuinely has no TLS.
- **Tracking Protection forces it on, but does not own it.** A new ETP-028
  in the shape of ETP-002: the umbrella forces the upgrade on and locks the
  row. It does NOT become a subordinate whose only home is the umbrella.

## The decision this change makes, and why

The obvious design is to fold the upgrade into Tracking Protection, which
already forces ClearURLs, the DNS blocklist, the content blocker and LocalCDN
on, and third-party cookies off. Plaintext http is a privacy problem: an on-path
observer reads the full URL, and an injecting middlebox can add trackers that no
list of ours will ever see.

It is rejected as the *only* home for the setting, because of what the umbrella
is used for in practice. Tracking Protection is the switch a user turns off to
make a broken site work: that is what this app's own support answer told the
reporter to do two messages before this proposal was written, and it is what its
anti-fingerprinting noise and its third-party-cookie forcing make necessary from
time to time. If the https upgrade rides the umbrella, then debugging a captcha
silently downgrades a login page to cleartext, and neither the user nor the app
says a word about it.

So: a security default must not be collateral of a privacy toggle. The upgrade
is on for everyone by default, the umbrella forces it and locks it, and turning
the umbrella off returns the setting to the user's own value rather than to
`false`.

## Scope

**In.** Main-frame navigations, and the initial load of a site.

**Out.** Sub-resources and sub-frames. They are governed by the engine's own
mixed-content rules, and intercepting them on Android means going through
`FastSubresourceInterceptor`, where a blocked request already returns an empty
`200` rather than an error (BUG-013 gap 4). Turning a scheme decision into that
shape would produce silent, bodyless successes on the upgrade path, which is the
failure mode this repo has spent the most time on.

**Out.** Persisting the http-only host set. It would put a per-host artifact on
disk that ARCH-001 has to reason about, and a poisoned entry would be sticky
across launches with no way for a user to see or clear it. Session-scoped memory
avoids both, and costs one failed connection per host per launch.

## Ordering: the upgrade follows the navigation verdict

The upgrade SHALL be applied after the navigation decision has allowed the URL,
never before. Taken first, an upgraded URL would arrive at the engine as a
different URL from the one the site asked for, and a scheme rewrite would become
a way to re-enter the pipeline with `blockAutoRedirects`, the gesture
requirement and cross-domain nested routing already behind it.

This is CAPTCHA-008's lesson, applied before it is learned a second time: the
captcha allow was taken before the navigation verdict for eight months and was
a parent-webview redirect primitive the whole time.

## Impact

- New: `lib/services/https_upgrade_engine.dart`,
  `test/https_upgrade_engine_test.dart`,
  `openspec/specs/https-upgrade/spec.md` (on archive).
- `lib/settings/app_prefs.dart`: `httpsUpgradeEnabled: true`.
- `lib/web_view_model.dart`: the per-site field, `effectiveHttpsUpgradeEnabled`,
  `toJson`/`fromJson`, the `WebViewConfig`, and both `launchUrlFunc` call sites.
- `lib/main.dart`, `lib/screens/inappbrowser.dart`: the per-site field through
  `launchUrl` and the nested `InAppWebViewScreen`, per the five-step checklist
  in CLAUDE.md, or a nested webview silently keeps loading plaintext.
- `lib/services/webview.dart`: the call site in `shouldOverrideUrlLoading`
  (after `config.shouldOverrideUrlLoading` returns) and the error path that
  triggers fallback.
- `lib/screens/site_behaviour.dart` or the Privacy screen: the per-site row.
- `lib/l10n/app_*.arb` (67 files): two keys, in their own commit.
- `openspec/specs/tracking-protection/spec.md`: ETP-028.
- `CLAUDE.md`: the `https-upgrade` row in the OpenSpec table, marked *(change)*.
