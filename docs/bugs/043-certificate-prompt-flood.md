# BUG-043: The "Untrusted certificate" prompt floods the user

Status: open

**Spec:** [tls-trust-prompt](../../openspec/specs/tls-trust-prompt/spec.md)
TLS-001, TLS-002, TLS-009, TLS-010, TLS-011, TLS-012, TLS-013
**Tests:** [test/tls_network_sign_in_test.dart](../../test/tls_network_sign_in_test.dart),
[test/tls_loopback_sinkhole_test.dart](../../test/tls_loopback_sinkhole_test.dart),
[test/proxy_leg_failure_test.dart](../../test/proxy_leg_failure_test.dart)

## Symptom

One "Untrusted certificate" dialog after another, each naming a host the user
did not type and offering "Trust this site". Most recently: on an airline's
Wi-Fi before signing in, the controller (Aruba) answered every HTTPS
connection with its own certificate (`securelogin.arubanetworks.com`), and a
loaded Discord retried, prompting for `discord.com`, then its CDN, then again.
The flood is the harm: each dialog is one more chance to tap "Trust this
site", which pins the interceptor's certificate for the site for good and
sends the site's cookies to it.

## Root mechanism / invariant

Every rejected TLS handshake reaches the trust callback (Android's
`onReceivedSslError`, WPE's TLS error), and the code turned each one into a
question for the user. One cause behind a page makes many rejections: every
host the page loads, every retry. The invariant is that the user is asked
once per decision they can actually make, and never about a certificate that
is not the site's own. Each fix below recognised one cause that is not a
decision.

## Fix attempts

1. **2026-05-11, `5ef11749` (#320).** Prompt and pin, with a re-entrancy
   guard per host:port in the dialog. *Why:* self-signed sites failed with no
   way through. *Why partial:* on iOS and macOS the plugin forwards every
   handshake, so every public site prompted; the guard only stopped stacked
   dialogs for one host.
2. **2026-05-13, `3f1410d7` (#336).** Defer to the OS on iOS and macOS, and
   wipe the pins made meanwhile (TLS-001, TLS-008, later TLS-009). *Why:* the
   prompt must follow the OS's rejection, not replace its check. *Why
   partial:* covers handshakes the OS accepts; a cause that makes the OS
   reject many handshakes still prompts once per host.
3. **2026-06-04, `a0fc3412` (#400).** A self-signed `CN=localhost`
   certificate for a remote host is cancelled silently (TLS-010). *Why:* a
   device DNS blocker answering blocked trackers on 127.0.0.1 raised one
   dialog per tracker. *Why partial:* recognises one interceptor by the shape
   of its certificate; a captive portal's certificate names a real host.
4. **2026-10-31, `f6f9e0de` (#872).** A tunnel the proxy did not open is not
   a certificate error (TLS-011). *Why:* Android reports it as
   `FAILED_SSL_HANDSHAKE` and the prompt asked about a certificate that did
   not exist. *Why partial:* a failure with no certificate; an interceptor
   that presents one still prompts.
5. **2026-11-03, this change.** While the OS says the network holds traffic
   for a sign-in page (Android's `NET_CAPABILITY_CAPTIVE_PORTAL`,
   NetworkManager's `PORTAL`), no rejected certificate is asked about, pinned
   or let through on a pin, and the user is told once per network to sign in
   (TLS-012). Apart from that, a certificate the user declined is not asked
   about again in the run, for any host, and one certificate is asked about
   once at a time (TLS-013), which moved the dialog's re-entrancy guard into
   `WebViewTls`. *Why:* the portal is a fact the OS already holds, and one
   interceptor's certificate is one decision however many hosts it answers
   for. *Why partial:* see the gaps.

## Known open gaps

- A portal the OS has not flagged (its probe blocked, or the seconds before
  Android's probe finishes) still prompts, once per distinct certificate.
- Linux reads NetworkManager only: a desktop without it, NetworkManager with
  its connectivity check off, or a sandbox without system-bus access to it
  reports no portal.
- Android does not say whether a rejected handshake was the main frame's, so
  a sub-resource still prompts where a browser would block it silently.
- A decline made by accident holds until the app restarts.
- A portal certificate pinned before this change stays in Trusted
  certificates. Behind a portal it is no longer honoured; on a network the OS
  validated it would be, until revoked there.
