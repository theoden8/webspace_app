# HTTP authentication prompt

## ADDED Requirements

### Requirement: HTTPAUTH-001 - The proxy router's challenge is resolved first

Every webview's `onReceivedHttpAuthRequest` SHALL go through
`answerHttpAuthChallenge`, which SHALL ask `ProxyRouterService.ownsChallenge`
before anything else. A challenge the router owns SHALL be answered by the
router alone (PROXY-013). It SHALL NOT reach the sign-in prompt and SHALL NOT
be answered from saved sign-ins.

Android's callback carries only host and realm, so the relay's `407` and a
site's `401` arrive at the same handler. The router claims its own by the
loopback host it bound and its per-run realm nonce; anything it does not claim
is a site's.

#### Scenario: The relay's challenge never reaches the user

**Given** router mode is active on Android
**When** the relay at its bound loopback host challenges with its realm nonce
**Then** the router's credential answers it
**And** no sign-in dialog opens
**And** no saved sign-in is read

#### Scenario: A site's challenge is not answered with the router token

**Given** router mode is active on Android
**When** `nas.example.com` answers `401` with `WWW-Authenticate: Basic`
**Then** the router does not claim it
**And** the site's `HttpAuthSession` decides it

---

### Requirement: HTTPAUTH-002 - Only the site's own hosts can ask

`HttpAuthSession` SHALL answer a challenge only when its host has the same
base domain (`getBaseDomain`) as the URL the webview was opened for: the unit
the app already isolates cookies by and keeps navigations in-webview by. A
private suffix such as `github.io` is not a base domain, so one `github.io`
subdomain cannot raise a prompt for another. A challenge from any other host,
and a challenge the platform marks as a proxy's, SHALL be left to the
platform, which cancels.

A page can embed a `401` from any host. A dialog naming a host the user never
opened reads as the app asking, which is a phishing surface; browsers suppress
cross-origin subresource prompts for the same reason.

#### Scenario: An embedded third-party 401 is not prompted

**Given** a site opened at `https://nas.example.com/`
**When** an image on the page from `tracker.test` answers `401`
**Then** no dialog opens
**And** the image fails as it did before this change

#### Scenario: A proxy challenge on Apple is left to the proxy settings

**Given** a challenge whose protection space carries a `proxyType`
**When** it reaches the site's session
**Then** the session returns no credential

---

### Requirement: HTTPAUTH-003 - A sign-in dialog collects the credential

When no saved sign-in answers a challenge, the app SHALL show a dialog naming
the challenging host, with username and password fields, and SHALL answer the
challenge with `PROCEED` and what the user typed. Cancel SHALL leave the
challenge to the platform, so the server's own `401` body renders.

The dialog SHALL NOT show the server's realm string: it is text the server
chose, and inside the app's dialog it reads as the app's own words.

Challenges for one protection space (host, realm) that arrive while its dialog
is open SHALL share that dialog and its answer. The parent webview, a popup,
and a nested `InAppWebViewScreen` SHALL all show the same dialog.

#### Scenario: An htpasswd folder signs in once for the whole page

**Given** `https://nas.example.com/files/` behind `auth_basic`, whose page
loads an image and `fetch()`es JSON from the same folder
**When** the user signs in through the dialog
**Then** the page, the image and the JSON all load
**And** only one dialog was shown

#### Scenario: Cancel shows the server's page

**Given** the sign-in dialog is open
**When** the user taps Cancel
**Then** the webview renders the server's `401` response body

---

### Requirement: HTTPAUTH-004 - Remembered per site, in secure storage

The dialog SHALL offer "Remember for this site". A remembered sign-in SHALL be
stored by `HttpAuthSecureStorage` in `flutter_secure_storage`, keyed by
(siteId, host, realm), and SHALL answer that site's later challenges for that
protection space without a dialog.

The key is host and realm, not origin, because Android's callback carries
neither port nor scheme. The cost is that a sign-in saved over https is also
sent to an http challenge from the same host and realm, as Android WebView's
own `setHttpAuthUsernamePassword` would. The HTTPS upgrade (HTTPS-001), on by
default, keeps main-frame navigations on https; a user who cannot rely on it
for a host leaves Remember unticked.

The platform's own credential store SHALL NOT be used: every `PROCEED` SHALL
carry `permanentPersistence: false`. That store is app-wide, so one site's
saved password would answer another site's challenge for the same host.

What a site may do with sign-ins SHALL follow `effectiveHttpAuthMemory`:

| Site | Reads saved | Offers to save |
|---|---|---|
| ordinary | yes | yes |
| incognito | yes | no |
| archive-tier | no | no |

An incognito site uses a saved sign-in the way a private window still fills a
saved password, and saves nothing new. An archive-tier site touches neither,
because the store is app-tier secure storage keyed by the cleartext siteId
(ARCH-001, ARCH-006). Nested webviews SHALL carry the opening site's value.

#### Scenario: A remembered sign-in answers without a prompt

**Given** the user signed in to `nas.example.com` with Remember ticked
**When** the site is opened again after an app restart and the server
challenges
**Then** the saved sign-in answers
**And** no dialog opens

#### Scenario: Incognito does not offer to remember

**Given** an incognito site
**When** the sign-in dialog opens
**Then** it has no Remember checkbox
**And** nothing is written to `HttpAuthSecureStorage`

#### Scenario: An archive-tier site leaves no app-tier trace

**Given** an archive-tier site
**When** it is challenged and the user signs in
**Then** `HttpAuthSecureStorage` is neither read nor written for its siteId

---

### Requirement: HTTPAUTH-005 - A refused credential asks again, once

When a protection space is challenged again after this webview answered it,
or the platform reports an earlier failure, the dialog SHALL say the username
and password were not accepted, SHALL prefill the saved username or else the
one last sent for that protection space (whether or not it was saved; the
password is never kept), and SHALL tick Remember when a saved sign-in exists. A saved sign-in SHALL be offered at most
once per protection space per webview, so a refused one cannot loop against
the server. Unticking Remember on that dialog SHALL forget the saved sign-in.

Android's `previousFailureCount` is one static shared by every webview in the
process and already reads 1 on a first challenge, so it is not consulted
there; the session's own record of what it answered is.

#### Scenario: A wrong password

**Given** the user typed a wrong password, with Remember unticked
**When** the server challenges again
**Then** the dialog reopens with "That username and password were not
accepted."
**And** the username field still holds what was typed

#### Scenario: A saved password that changed on the server

**Given** a saved sign-in the server now refuses
**When** the saved sign-in is sent and the server challenges again
**Then** the dialog opens marked as a retry, instead of sending it again

---

### Requirement: HTTPAUTH-006 - Saved sign-ins never leave the device

No saved sign-in SHALL be reachable from `WebViewModel`, so none SHALL appear
in `toJson`, a settings backup, or a site QR code. Saved sign-ins SHALL be
swept against the full active set of sites (incognito included) at startup,
after an import and after a delete. Site settings SHALL show a Saved sign-ins
row with the count and a Clear action, hidden for archive-tier sites.

#### Scenario: Export carries no sign-in

**Given** a saved sign-in for a site
**When** settings are exported
**Then** neither its username nor its password appears in the backup

#### Scenario: Deleting a site forgets its sign-ins

**Given** a site with a saved sign-in
**When** the site is deleted
**Then** its entry is removed from `HttpAuthSecureStorage`

---

### Requirement: HTTPAUTH-007 - Covered against real engines

`integration_test/http_auth_test.dart` SHALL serve an htpasswd-style folder
from loopback and SHALL assert, against the real engine, that a saved sign-in
answers without a dialog, that the dialog signs in after a refused password,
and that the page's image and `fetch()` load in both cases. It SHALL run on
the Android emulator (`scripts/run_android_http_auth_tests.sh`) and the macOS
integration job.

Linux SHALL be skipped until the fork's WPE plugin sends
`previousFailureCount` as an integer. Today it sends null, the shared Dart
`HttpAuthenticationChallenge.fromMap` throws on it, and the platform cancels
before the app's handler runs.

#### Scenario: Linux gap is visible, not silent

**Given** the Linux integration job
**When** it reaches `http_auth_test.dart`
**Then** both cases report as skipped
