## 1. Specify

- [x] 1.1 Write the `external-scheme-handling` delta (EXT-010 to EXT-012).
- [x] 1.2 Add the `magnet-link-support` change to the
  `external-scheme-handling` row of the OpenSpec table in `CLAUDE.md`.

## 2. The parser

- [ ] 2.1 `lib/services/magnet_uri.dart`: `dn`, `xt` (btih, btmh) and the
  shortened hash; pure. Seed from the April parser at `81cd9c1`.
- [ ] 2.2 Tests: names with escapes, several `xt`, none, hostile lengths.

## 3. Wire it

- [ ] 3.1 The prompt's magnet case (EXT-010); strings in `app_en.arb`, the
  other locales in their own commit.
- [ ] 3.2 One validation of site URLs for Add Site, editing, QR and backup
  import that refuses external schemes (EXT-011).
- [ ] 3.3 The URL bar hands an external scheme to the prompt (EXT-011).
- [ ] 3.4 A test that a magnet with trackers and seeds leaves no request
  through `outboundHttp` (EXT-012).
