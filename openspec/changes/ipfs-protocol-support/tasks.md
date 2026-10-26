## 1. Specify

- [x] 1.1 Write `specs/ipfs-protocol/spec.md` (IPFS-001 to IPFS-006).
- [x] 1.2 Add the `ipfs-protocol` row to the OpenSpec table in `CLAUDE.md`,
  marked *(change)* until archived.

## 2. The engine

- [ ] 2.1 `lib/services/ipfs_gateway_engine.dart`: site URL to gateway URL and
  back, CIDv0 to CIDv1 base32, IPNS key and DNSLink inlining; pure.
- [ ] 2.2 Tests from the IPFS gateway spec's vectors, with invalid CIDs and
  names that must not load.

## 3. Wire it

- [ ] 3.1 The `AppPref` for the gateway and its row with the hint (IPFS-003);
  strings in `app_en.arb`, the other locales in their own commit.
- [ ] 3.2 `ensureUrlScheme` and the Add Site preview (IPFS-001).
- [ ] 3.3 The first load and the navigation gate rewrite through the engine;
  the rewrite is a reissue that asks the coverage gate (IPFS-006).
- [ ] 3.4 The gateway's `ipfs.` and `ipns.` labels as private suffixes in
  `url_host.dart` (IPFS-005).
- [ ] 3.5 The URL bar, site info sheet and share map back (IPFS-004).
