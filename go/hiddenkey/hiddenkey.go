// Copyright (c) 2026 Kirill Rodriguez
// SPDX-License-Identifier: BSD-3-Clause

// Package hiddenkey is the Elligator 2 key hiding obfs4's handshake uses: a
// Curve25519 key pair whose public key is sent as a 32-byte representative
// that cannot be told from random bytes.
//
// It is glue over Monocypher's own C (crypto_x25519_dirty_fast,
// crypto_elligator_rev, crypto_elligator_map), which cgo compiles from
// monocypher.c and monocypher.h in this directory. Those two files are not
// committed: README.md says how to fetch them.
//
// The encoding, as Monocypher defines it (crypto_elligator_map(3monocypher),
// STANDARDS):
//
//   - The map is Elligator 2 on Curve25519, v^2 = u^3 + A*u^2 + u with
//     A = 486662, and the non-square Z = 2. Its u is RFC 9380's
//     map_to_curve_elligator2 for the curve25519 suites.
//   - A representative is a little-endian field element r with
//     0 <= r <= (p-1)/2, in bits 0 to 253. Bits 254 and 255 are random
//     padding, which the decoder ignores.
//   - A public key is u, little-endian, as X25519 takes it.
//
// A public key carries a random low-order component (a "dirty" key), because
// keys confined to the prime-order subgroup would set the representatives
// apart from random ones. X25519 clamps its scalar to a multiple of 8, so the
// component never reaches a shared secret.
package hiddenkey

/*
#include "monocypher.h"
*/
import "C"

import "unsafe"

// ScalarBaseMult derives from privateKey a Curve25519 key pair whose public
// key has an Elligator 2 representative. It returns false when it has none
// (about half the time); the caller then draws another private key. tweak
// is a random byte for the choices the encoding leaves free.
//
// On false, publicKey and representative are left unchanged.
func ScalarBaseMult(publicKey, representative, privateKey *[32]byte, tweak byte) bool {
	var pub, repr [32]byte
	dirtyPublicKey(&pub, privateKey)
	if !hide(&repr, &pub, tweak) {
		return false
	}
	*publicKey, *representative = pub, repr
	return true
}

// RepresentativeToPublicKey maps a representative back to its public key.
func RepresentativeToPublicKey(publicKey, representative *[32]byte) {
	C.crypto_elligator_map(ptr(publicKey), ptr(representative))
}

// dirtyPublicKey sets publicKey to the u of clamp(privateKey)*B plus k times
// a point of order 8, k being privateKey's low three bits, which clamping
// discards. Monocypher's crypto_x25519_dirty_small gives the same key in
// twice the time (crypto_x25519(3monocypher), DIRTY PUBLIC KEY GENERATION);
// crypto_elligator_key_pair uses the fast one.
func dirtyPublicKey(publicKey, privateKey *[32]byte) {
	C.crypto_x25519_dirty_fast(ptr(publicKey), ptr(privateKey))
}

// hide sets representative to the representative of publicKey and reports
// whether it has one.
//
// tweak, as monocypher.c reads it in crypto_elligator_rev (the man page
// calls the layout an implementation detail): bit 0, the least significant
// (`tweak & 1`; the comment above the function calls it "Bit 1"), is the
// sign of v, so it picks which of u's two representatives is sent; bits 6
// and 7 (`tweak & 0xc0`) become bits 254 and 255 of the representative;
// bits 1 to 5 are unused.
func hide(representative, publicKey *[32]byte, tweak byte) bool {
	return C.crypto_elligator_rev(ptr(representative), ptr(publicKey), C.uint8_t(tweak)) == 0
}

func ptr(b *[32]byte) *C.uint8_t { return (*C.uint8_t)(unsafe.Pointer(&b[0])) }
