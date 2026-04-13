# Change: Gemini Protocol Support

## Summary

Add `gemini://` URL scheme support to WebSpace by implementing a native Gemini protocol client that fetches `text/gemini` content and renders it as styled HTML inside the existing webview. Unlike IPFS (which proxies through an HTTP gateway), Gemini requires a native client because there are no widely available public Gemini-to-HTTP proxies, and the protocol is simple enough (RFC-like spec, TLS-only, request/response) to implement directly in Dart.

## Motivation

Gemini is a lightweight internet protocol that sits between Gopher and HTTP. It's popular in privacy-focused and minimalist computing communities — the same audience WebSpace serves. Gemini's simplicity (no cookies, no JavaScript, no tracking) makes it a natural fit for a privacy-oriented browser. Adding Gemini support would make WebSpace one of very few mobile apps that can browse Gemini content natively.

## Approach: Native Client + HTML Rendering

1. **Dart Gemini client**: Open a TLS socket to the Gemini server, send the URL, read the response header and body. The Gemini protocol is a single request/response over TLS — no HTTP framing, no headers beyond a status line and MIME type.
2. **Gemtext-to-HTML converter**: Parse `text/gemini` markup (links, headings, lists, preformatted blocks, quotes) into styled HTML.
3. **Webview rendering**: Load the generated HTML via `loadHtmlString()` / `loadData()` into the existing InAppWebView. Intercept link clicks to handle `gemini://` links internally.

### Gemini Protocol Overview

```
Client → Server:  gemini://example.com/page\r\n    (URL, max 1024 bytes)
Server → Client:  20 text/gemini\r\n                  (status + MIME)
                   # Hello World\n                    (body)
                   => gemini://example.com/other Link\n
```

- Port 1965 (default)
- TLS required (TOFU — Trust On First Use certificate model)
- No cookies, no headers, no POST
- Content type: `text/gemini` (line-oriented markup)

### Gemtext Markup

| Syntax | Meaning |
|--------|---------|
| `# Heading` | H1 heading |
| `## Heading` | H2 heading |
| `### Heading` | H3 heading |
| `=> URL [label]` | Link (with optional display text) |
| `* item` | Unordered list item |
| `` ```alt `` | Toggle preformatted block |
| `> quote` | Block quote |
| plain text | Paragraph |

## Requirements

### REQ-GEMINI-001: Recognize Gemini URL Scheme

The system SHALL accept `gemini://` URLs in:
- Add Site screen URL input
- URL bar text submission
- Site editing dialog

When this scheme is detected, the system SHALL NOT prepend `https://`.

### REQ-GEMINI-002: Native Gemini Client

The system SHALL implement a Gemini protocol client in Dart that:
- Opens a TLS connection to the target host on port 1965 (or custom port if specified in URL)
- Sends the full URL followed by `\r\n`
- Reads the response status line (2-digit status code + space + meta)
- Reads the response body for success status codes (2x)
- Handles redirects (3x status) up to a maximum of 5 hops
- Reports errors for failure status codes (4x, 5x, 6x)

### REQ-GEMINI-003: TLS with TOFU

The Gemini client SHALL use Trust On First Use (TOFU) certificate validation:
- On first visit, accept the server's self-signed certificate and store its fingerprint
- On subsequent visits, verify the certificate matches the stored fingerprint
- If the certificate changes, warn the user and let them accept or reject
- Certificate fingerprints persisted via SharedPreferences keyed by hostname

### REQ-GEMINI-004: Gemtext-to-HTML Rendering

The system SHALL convert `text/gemini` content to styled HTML:
- Parse all gemtext line types (headings, links, lists, preformatted, quotes, plain text)
- Apply a clean, readable CSS theme that respects the app's light/dark mode
- Gemini links (`=> gemini://...`) rendered as clickable `<a>` tags
- Non-gemini links (`=> https://...`) rendered with an external link indicator
- Preformatted blocks rendered in monospace with horizontal scroll

### REQ-GEMINI-005: Webview Content Loading

The system SHALL render Gemini content using the existing webview's `loadHtmlString()` / `loadData()` method:
- Set `mimeType: 'text/html'`
- Set `baseUrl` to the original `gemini://` URL
- Load generated HTML into the webview

### REQ-GEMINI-006: Navigation Interception

When a user clicks a `gemini://` link within rendered Gemini content:
- `shouldOverrideUrlLoading` SHALL intercept the navigation
- The Gemini client SHALL fetch the linked content
- The webview SHALL be updated with the new rendered HTML
- The URL bar SHALL update to show the new `gemini://` URL

### REQ-GEMINI-007: Skip DNS Validation

The Add Site preview/validation SHALL skip DNS lookup for `gemini://` URLs and instead attempt a Gemini connection to validate the server is reachable.

### REQ-GEMINI-008: Disable Inapplicable Features for Gemini Sites

For sites loaded via `gemini://`, the following features SHALL be disabled/hidden:
- JavaScript injection (user scripts) — Gemini has no JS
- Cookie management — Gemini has no cookies
- Content blocker / DNS blocklist — not applicable
- ClearURLs — Gemini has no tracking parameters
- Proxy settings — Gemini uses direct TLS (proxy support is a future enhancement)

### REQ-GEMINI-009: Domain Comparison and Cookie Isolation

Gemini sites SHALL participate in domain comparison using the hostname from the `gemini://` URL. Since Gemini has no cookies, cookie isolation is inherently satisfied — no conflict handling needed.

## Affected Files

| File | Change |
|------|--------|
| `lib/services/gemini_client.dart` | **New** — Gemini protocol client (TLS, request/response, redirects) |
| `lib/services/gemini_renderer.dart` | **New** — Gemtext-to-HTML converter with theming |
| `lib/services/gemini_tofu.dart` | **New** — TOFU certificate store |
| `lib/screens/add_site.dart` | Accept `gemini://` scheme; skip DNS validation |
| `lib/widgets/url_bar.dart` | Accept scheme; display `gemini://` URL; Gemini indicator |
| `lib/services/webview.dart` | Navigation interception; `loadHtmlString` for Gemini content |
| `lib/web_view_model.dart` | `isGemini` flag; disable inapplicable features; domain comparison |
| `lib/screens/settings.dart` | Hide inapplicable settings for Gemini sites |

## Complexity Assessment

| Component | Effort | Notes |
|-----------|--------|-------|
| Gemini client | Medium | Simple protocol, but TLS + TOFU needs care |
| Gemtext parser | Low | Line-oriented format, straightforward |
| HTML renderer | Low-Medium | CSS theming for light/dark mode |
| URL input changes | Low | Same pattern as IPFS — recognize scheme |
| Navigation interception | Medium | Async fetch + render in webview |
| Feature gating | Low | Conditional UI based on `isGemini` |

**Overall: Medium complexity** — more involved than IPFS (which is just URL rewriting) because it requires a native protocol client and content renderer, but the Gemini protocol itself is intentionally simple.

## Out of Scope

- Client certificates for Gemini authentication (status 6x)
- Gemini input requests (status 1x) — interactive prompts
- Proxying Gemini through SOCKS5/Tor
- Caching Gemini responses
- Bookmarks or history specific to Gemini

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| TLS TOFU complexity on mobile | Use Dart's `SecureSocket` with custom `onBadCertificate` |
| Platform socket restrictions (iOS) | Test early; fallback to a Gemini-to-HTTP portal if needed |
| Gemtext rendering fidelity | Keep it simple — Gemini's format is intentionally minimal |
| Large Gemini responses | Stream body with a size cap (e.g. 5 MB) |
