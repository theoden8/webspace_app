# hiddenkey

obfs4's Elligator 2 key hiding, as the two functions its ntor handshake calls:

```go
func ScalarBaseMult(publicKey, representative, privateKey *[32]byte, tweak byte) bool
func RepresentativeToPublicKey(publicKey, representative *[32]byte)
```

The package is cgo glue over Monocypher's C:

| Go | Monocypher |
|---|---|
| `ScalarBaseMult` | `crypto_x25519_dirty_fast`, then `crypto_elligator_rev`; false when rev finds no representative |
| `RepresentativeToPublicKey` | `crypto_elligator_map` |

## Fetch Monocypher first

`monocypher.c` and `monocypher.h` are not committed (`.gitignore`). Before
building, put them beside `hiddenkey.go`:

```sh
./fetch-monocypher.sh                     # clones tag 4.0.3
./fetch-monocypher.sh /path/to/Monocypher # or copies from a local tree or its src/
```

The script copies a file only if its SHA-256 matches the pin:

| File | SHA-256 |
|---|---|
| `src/monocypher.c` | `f1f838cdd483bdebe0df0ff5c5ed60535e496f769c6a2f933ac4c0b114207123` |
| `src/monocypher.h` | `fcaf6ed771358bb4f40fba016f6518ae86ec02b1b877d2cc35ad92d3a26fd7b3` |

The pins are of Monocypher 4.0.3 as its git tag holds the files (first line
`// Monocypher version __git__`); a copy from elsewhere, such as a release
tarball, may differ. `MONOCYPHER_REPO` and `MONOCYPHER_TAG` override the clone.

## Test

```sh
go test ./...   # needs cgo and a C compiler
```

| Test | Checks |
|---|---|
| `TestMonocypherMap`, `TestMonocypherRev`, `TestMonocypherKeyPair` | vectors from Monocypher's Python references ([testdata/README.md](testdata/README.md)) |
| `TestRFC9380` | RFC 9380 J.4 curve25519 `map_to_curve` vectors, with every padding pattern |
| `TestRoundTripAndAgreement`, `TestInverseOfMap` | round trips, padding and choice from the tweak, X25519 agreement with dirty and clean keys |
| `TestStatistics` | 20,000 key pairs drawn as obfs4 draws them: low-order component, padding bits, representative choice, every bit and byte |
| `internal/ntor` | lyrebird's ntor handshake and its tests, run over this package |

## Wire format

- The map is Elligator 2 on Curve25519 with non-square Z = 2.
- A representative is r in [0, (p-1)/2], little-endian, in bits 0 to 253.
- Bits 254 and 255 are random padding from bits 6 and 7 of the tweak.
  `crypto_elligator_map` ignores them, as obfs4's `ntor_test.go` does
  (`clamped[31] &= 63`).
- Bit 0 of the tweak picks which of the public key's two representatives is
  sent. Bits 1 to 5 are unused.
- The public key's low-order component comes from the private key's low three
  bits, which X25519's clamping discards.

Sources: [PROVENANCE.md](PROVENANCE.md). Licence: [LICENSE](LICENSE).
