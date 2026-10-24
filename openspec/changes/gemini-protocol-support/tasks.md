## 1. Specify

- [x] 1.1 Write `specs/gemini-protocol/spec.md` (GEMINI-001 to GEMINI-007).
- [ ] 1.2 Add the client's row to the LEAK-007 coverage matrix in
  `openspec/specs/ip-leakage/spec.md`.
- [x] 1.3 Add the `gemini-protocol` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until archived.

## 2. Engines

- [ ] 2.1 `lib/services/gemtext_engine.dart`: gemtext to HTML, pure, every
  capsule byte escaped, CSP with no script and no fetch. Seed from the April
  renderer at `81cd9c1`.
- [ ] 2.2 `lib/services/gemini_response.dart`: the sealed result (GEMINI-007)
  and the header parser, with the 1029-byte header and body caps.
- [ ] 2.3 Tests for both with hostile input: markup, oversized headers,
  truncated bodies, every status class.

## 3. The seam

- [ ] 3.1 `GeminiClient` over the site's effective proxy: `socksConnectSecure`
  for SOCKS5 and Tor, `CONNECT` for HTTP and HTTPS proxies, a direct
  `SecureSocket` only for `DEFAULT`, refusing onion hosts there (LEAK-016).
- [ ] 3.2 First-use pins in `TrustedHostsService`'s store; a changed pin goes
  to TLS-005's prompt; archive-tier pins kept in memory only.
- [ ] 3.3 Real-socket tests: a loopback TLS capsule, the SOCKS fixture in
  `integration_test/socks5_fixture.dart`, redirect hops, the onion refusal.

## 4. Wire it

- [ ] 4.1 `ensureUrlScheme` and the Add Site preview (GEMINI-001).
- [ ] 4.2 The webview's navigation gate serves `gemini://` through the client
  and loads data with the capsule URL as base (GEMINI-006); the first load and
  the nested screen take the same path.
- [ ] 4.3 Status pages and the input field; strings in `app_en.arb`, the
  other locales in their own commit.
