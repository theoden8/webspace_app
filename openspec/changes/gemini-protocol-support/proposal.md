# Gemini protocol support

## Why

Gemini is a small request/response protocol over TLS: no cookies, no scripts,
no third-party requests. Its audience overlaps with this app's, and no webview
engine speaks it, so a `gemini://` link today falls into the external-scheme
prompt (EXT-004) and goes nowhere.

The first draft of this change (PR #200, April 2026) fetched Gemini over a
direct TLS socket and left the proxy as "a future enhancement". The app has
since made that a leak by definition: every Dart-side fetch goes through the
site's route (LEAK-002), and an onion host never leaves on a direct one
(LEAK-016). This rewrite makes the route part of the client, not a follow-up.

## What changes

| Piece | Where it lives | Joins |
|---|---|---|
| A capsule is a site | `initUrl` keeps `gemini://`; the site's `SitePosture` applies | `ensureUrlScheme` keeps the scheme (GEMINI-001) |
| One request per page | `GeminiClient`, a new outbound seam beside `outboundHttp` | the site's effective proxy: Tor, SOCKS5, HTTP `CONNECT`; refuses what the route cannot carry (GEMINI-002, GEMINI-003) |
| Trust | first-use pin in `TrustedHostsService`'s store | TLS-005's rotation prompt, never a silent re-pin (GEMINI-004) |
| Rendering | a pure gemtext-to-HTML engine | every byte of the capsule escaped; the document runs no script and loads nothing (GEMINI-005) |
| Navigation | the webview's navigation gate | a `gemini://` link is fetched by the client and loaded as data; any other scheme goes the way it goes today (GEMINI-006) |
| Status lines | the client's result type, sealed | input (1x), redirects (3x), failures (4x/5x), client certificates (6x) each have a case (GEMINI-007) |

## What does not change

- Containers, the site list, backups and QR codes carry a `gemini://` site
  like any other: its URL is a string the site already stores.
- Nothing about http(s) navigation, the proxy rules or the onion rule.

## Out of scope

- Client certificates (status 6x): reported, not answered.
- Writing Gemini (Titan) and any caching of responses.
- A Gemini-to-HTTP portal as a fallback: it would hand every capsule a user
  opens to a third party.

## Prior work

The April draft's client, renderer and tests sit at `81cd9c1` on this
branch's old history. The renderer is reusable; the client opens a direct
socket and has to be rebuilt on the seam (GEMINI-002).
