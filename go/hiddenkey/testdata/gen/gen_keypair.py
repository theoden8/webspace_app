#! /usr/bin/env python3
# Copyright (c) 2026 Kirill Rodriguez. BSD-3-Clause, see ../../LICENSE.
#
# Writes testdata/keypair.vec: key pairs made the way ScalarBaseMult makes
# them, computed with Monocypher's Python references (monocypher/, copied
# unmodified from Monocypher's tests/gen/):
#
#   public key     = u of trim(sk)*B + (sk mod 8)*lop    (elligator_scalarmult.scalarmult,
#                                                       which cross-checks five ways)
#   representative = curve_to_hash(u, tweak bit 0) + (tweak >> 6) * 2^254
#
# Each record is four lines and a blank one, every value little-endian hex
# ending in ':' as Monocypher's own .vec files are:
#   secret key, tweak, 00 (success) or ff (no representative),
#   public key, representative (empty on failure).
#
# Run from this directory: python3 gen_keypair.py > ../keypair.vec

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), 'monocypher'))

from elligator import can_curve_to_hash, curve_to_hash, hash_to_curve, print_raw
from elligator_scalarmult import scalarmult
from random import randrange, seed

seed(20261103)

def record(sk, tweak):
    u = scalarmult(sk, sk % 8)
    print_raw(sk)
    print(format(tweak, '02x') + ':')
    if not can_curve_to_hash(u):
        print('ff:')
        u.print()
        print(':')
        print()
        return False
    r = curve_to_hash(u, tweak % 2 == 1)
    if r.val >= 2**254: raise ValueError('representative over 254 bits')
    if hash_to_curve(r)[0] != u: raise ValueError('round trip failure')
    print('00:')
    u.print()
    print_raw(r.val + (tweak // 64) * 2**254)
    print()
    return True

# Every low-order component, both representative choices, every pair of
# padding bits, for a success and for a failure; secret keys use all 256
# bits so the clamping of bits 0-2, 254 and 255 is exercised.
for cofactor in range(8):
    for choice in range(2):
        for pad in range(4):
            tweak = choice + randrange(0, 32) * 2 + pad * 64
            while True:
                sk = randrange(0, 2**253) * 8 + cofactor
                if not record(sk, tweak):
                    continue
                break
    while True:
        sk = randrange(0, 2**253) * 8 + cofactor
        if not record(sk, randrange(0, 256)):
            break
        # the success just written is kept as an extra vector
