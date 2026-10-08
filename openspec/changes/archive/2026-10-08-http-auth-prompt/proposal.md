# HTTP authentication prompt

## Why

Issue #623: a site behind HTTP Basic authentication (an `auth_basic` folder
with an htpasswd file) shows "401 Authorization Required" and nothing else.
The reporter asked for per-site custom HTTP headers so they could send
`Authorization` themselves.

The 401 page is the app's own doing. `onReceivedHttpAuthRequest` was wired on
every webview for the Android proxy router (PROXY-013), and it returned null
for every challenge the router did not own. Null is the platform's cancel, so
every server-side challenge (Basic, Digest, NTLM, Negotiate) was refused
before the user saw it.

### Why not custom headers

A header set on a `URLRequest` rides only the loads the app starts itself: the
first load and a reload. Link clicks, form posts, subresources and `fetch()`
are the engine's, and none of them carry it. An htpasswd folder protects the
page's images and scripts too, so the page would arrive with every asset
broken. The value would also be a credential in a text field, which the app
would then have to keep out of backups, QR codes and logs. Answering the
challenge instead puts the credential in the engine's own auth cache, which
applies it to every later request for that protection space.

## What Changes

- **`HttpAuthSession`** (`lib/services/http_auth_engine.dart`): one per
  webview, pure Dart. Decides whether a challenge is answered from a saved
  sign-in, from the prompt, or left to the platform.
- **`answerHttpAuthChallenge`** (`lib/services/webview.dart`) replaces the
  router-only handler on the site webview and the popup. The router claims its
  own `407` first; only what it does not claim reaches the session.
- **Sign-in dialog** (`lib/widgets/http_auth_prompt.dart`): username,
  password, "Remember for this site". The server's realm is not shown.
- **`HttpAuthSecureStorage`** (`lib/services/http_auth_secure_storage.dart`):
  saved sign-ins in `flutter_secure_storage`, keyed by (siteId, host, realm).
  Never on `WebViewModel`, so never in a backup or QR code.
- **`HttpAuthMemory`**: `readWrite` for ordinary sites, `readOnly` for
  incognito, `off` for archive-tier. A POSTURE field, threaded through the
  nested-webview chain.
- **Site settings**: a "Saved sign-ins" row under Network with a count and a
  Clear action; hidden for archive-tier sites.
- **Orphan sweep**: saved sign-ins are configuration, swept against the full
  active set at startup, after import and after delete.

## Scope

**In.** Server challenges from hosts on the base domain of the page the
webview was opened for.

**Out.** Challenges from any other host. A page can embed a 401 from anywhere,
and a dialog naming a host the user never visited is a phishing surface; the
engine leaves those to the platform, which cancels, as before.

**Out.** Proxy challenges. Proxy credentials are the proxy settings' job
(PROXY-019), and Android cannot tell a proxy challenge from a server one, which
is why HTTPAUTH-002 is host-scoped rather than flag-scoped.

**Fork.** Linux needed a fork fix. Its WPE plugin sent `previousFailureCount`
as null, which the shared Dart type declares `int`, so
`HttpAuthenticationChallenge.fromMap` threw before the app's handler ran and
the platform cancelled; it also had no Linux native values for
`HttpAuthResponseAction`. Both are fixed in `v6.2.0-beta.3-privacy-v10` (sent
from `isRetry`), which this change pins.

## Impact

- New: `lib/services/http_auth_engine.dart`,
  `lib/services/http_auth_secure_storage.dart`,
  `lib/widgets/http_auth_prompt.dart`, `test/http_auth_engine_test.dart`,
  `test/http_auth_secure_storage_test.dart`, `test/http_auth_prompt_test.dart`,
  `integration_test/http_auth_test.dart`,
  `scripts/run_android_http_auth_tests.sh`.
- `lib/services/webview.dart`: `WebViewConfig.onHttpAuthRequest` and
  `httpAuthMemory`; the site and popup handlers.
- `lib/web_view_model.dart`, `lib/main.dart`, `lib/screens/inappbrowser.dart`:
  `effectiveHttpAuthMemory` through the five-step nested chain; the prompt
  callback on both surfaces; the three orphan GC sites.
- `lib/screens/settings.dart`: the Saved sign-ins row.
- `lib/l10n/app_*.arb`: twelve keys, translations in their own commit.
- `openspec/specs/archive/spec.md`: ARCH-006 matrix row.
