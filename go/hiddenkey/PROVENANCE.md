# Provenance

The sources this package was built from, their licences and what each was
used for.

| Source | Licence | Used for |
|---|---|---|
| [Monocypher](https://github.com/LoupVaillant/Monocypher) 4.0.3, `src/monocypher.c`, `src/monocypher.h` | CC0-1.0 or BSD-2-Clause | the C the package compiles: `crypto_x25519_dirty_fast`, `crypto_elligator_rev`, `crypto_elligator_map`. Put in place by `fetch-monocypher.sh`, not committed |
| Monocypher 4.0.2, `src/monocypher.c` | CC0-1.0 or BSD-2-Clause | how `crypto_elligator_rev` reads its tweak (`tweak & 1`, `tweak & 0xc0`) and which low-order point the dirty keys add |
| Monocypher 4.0.2, `doc/crypto_elligator_map.3monocypher`, `doc/crypto_x25519.3monocypher` | CC0-1.0 or BSD-2-Clause | the representative format (Z = 2, 254 bits, padding ignored by the map and random from rev); `crypto_x25519_dirty_fast` and `_small` give the same key |
| Monocypher 4.0.2, `tests/gen/elligator.py`, `elligator-direct.py`, `elligator-inverse.py`, `elligator_scalarmult.py` | CC0-1.0 or BSD-2-Clause | copied unmodified into `testdata/gen/monocypher/`, where they generate `testdata/*.vec` |
| Monocypher `LICENCE.md` (the same in 4.0.2 and 4.0.3) | | reproduced in `LICENSE` |
| [lyrebird](https://gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird) `common/ntor/ntor.go`, `common/ntor/ntor_test.go` | BSD-2-Clause | how obfs4's handshake calls the two functions; copied into `internal/ntor/`, with ntor.go's two lyrebird imports pointed at this module, to run the handshake and its tests over this package |
| lyrebird `doc/obfs4-spec.txt` | BSD-2-Clause | the byte order of keys and representatives (section 3) |
| [RFC 9380](https://www.rfc-editor.org/rfc/rfc9380), Hashing to Elliptic Curves | IETF Trust Legal Provisions (BCP 78) | the map's definition (sections 6.7.1 and 8.5); the curve25519 test vectors (appendix J.4) |
| `filippo.io/edwards25519` v1.1.0 | BSD-3-Clause | tests: Edwards point arithmetic |
| `gitlab.com/yawning/edwards25519-extra` v0.0.0-20231005122941-2149dcafc266 | BSD-3-Clause | tests: the Elligator 2 map to an Edwards point, as lyrebird's `ntor_test.go` uses it |
| `golang.org/x/crypto` v0.33.0 | BSD-3-Clause | tests: `curve25519.X25519`; `internal/ntor`: `curve25519`, `hkdf` |
| Go standard library | BSD-3-Clause | the rest |

## Monocypher 4.0.2 and 4.0.3

The header is the same in the two versions. In `monocypher.c`, the functions
this package calls reach four that changed:

- `fe_ccopy` and `fe_cswap`: unrolled, with a `volatile` mask, so a compiler
  cannot turn the constant-time select into a branch or an index. They run in
  `crypto_x25519_dirty_fast`'s table lookups (`lookup_add`, `select_lop`), and
  in `invsqrt`, `crypto_elligator_map` and `crypto_elligator_rev`.
- `store32_le` (under `fe_tobytes`) and `neq0` (under `fe_isequal`): casts and
  comments only.

Each computes the same values as before, and the vectors in `testdata/` pass
with either version.
