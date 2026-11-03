# Test vectors

Each `.vec` file is in Monocypher's format: one little-endian hex value per
line, each ending in `:`, and a blank line after each record. All three were
generated with Python 3.13.16 from Monocypher's own Python references,
copied unmodified into `gen/monocypher/` from Monocypher 4.0.2's `tests/gen/`. Each
script seeds Python's `random`, so a rerun reproduces the files byte for byte.

| File | Record | Made by |
|---|---|---|
| `elligator_dir.vec` | representative, u | `cd gen/monocypher && python3 elligator-direct.py > ../../elligator_dir.vec` |
| `elligator_inv.vec` | u, tweak, `00` (has a representative) or `ff`, representative | `cd gen/monocypher && python3 elligator-inverse.py > ../../elligator_inv.vec` |
| `keypair.vec` | secret key, tweak, `00` or `ff`, public key, representative | `cd gen && python3 gen_keypair.py > ../keypair.vec` |

- `elligator-direct.py` checks the paper's map against the fast one and the
  round trip, and varies the two padding bits of each representative.
- `elligator-inverse.py` covers u = 0, a failure for every low-order
  component, and a success for every low-order component, representative
  choice and padding pattern.
- `gen_keypair.py` (ours) builds the public key with Monocypher's
  `elligator_scalarmult.scalarmult`, which computes the dirty key five ways
  and requires them to agree, then hides it with `curve_to_hash`. It covers the
  same grid as `elligator-inverse.py`, with secret keys over all 256 bits.

Set `PYTHONDONTWRITEBYTECODE=1` to keep `__pycache__` out of `gen/`.
