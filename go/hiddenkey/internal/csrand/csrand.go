// Copyright (c) 2026 Kirill Rodriguez. BSD-3-Clause, see LICENSE at the
// module root.

// Package csrand stands in for lyrebird's common/csrand in the copied ntor
// handshake: the one function ntor.go calls, over crypto/rand.
package csrand

import "crypto/rand"

// Bytes fills buf with bytes from crypto/rand.
func Bytes(buf []byte) error {
	_, err := rand.Read(buf)
	return err
}
