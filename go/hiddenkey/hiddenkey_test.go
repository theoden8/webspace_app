// Copyright (c) 2026 Kirill Rodriguez
// SPDX-License-Identifier: BSD-3-Clause

package hiddenkey

import (
	"bytes"
	"crypto/sha512"
	"encoding/binary"
	"encoding/hex"
	"math"
	"math/big"
	"math/rand/v2"
	"os"
	"strings"
	"testing"

	"filippo.io/edwards25519"
	"filippo.io/edwards25519/field"
	"gitlab.com/yawning/edwards25519-extra/elligator2"
	"golang.org/x/crypto/curve25519"
)

var (
	fieldP   = new(big.Int).Sub(new(big.Int).Lsh(big.NewInt(1), 255), big.NewInt(19))
	halfP    = new(big.Int).Rsh(fieldP, 1) // (p-1)/2
	two254   = new(big.Int).Lsh(big.NewInt(1), 254)
	feA      = new(field.Element).Mult32(new(field.Element).One(), 486662)
	feZero   = new(field.Element).Zero()
	scMinus1 = mustScalar("ecd3f55c1a631258d69cf7a2def9de1400000000000000000000000000000010") // L-1
)

// monocypherLop is low_order_point_1 of Monocypher's elligator_scalarmult.py,
// Edwards-encoded: the order-8 point whose multiples crypto_x25519_dirty_fast
// adds, k times for a secret key whose low three bits are k.
var monocypherLop = mustPoint("26e8958fc2b227b045c3f489f2ef98f0d5dfac05d3c63339b13802886d53fc05")

func mustScalar(h string) *edwards25519.Scalar {
	s, err := edwards25519.NewScalar().SetCanonicalBytes(mustHex(h))
	if err != nil {
		panic(err)
	}
	return s
}

func mustPoint(h string) *edwards25519.Point {
	p, err := new(edwards25519.Point).SetBytes(mustHex(h))
	if err != nil {
		panic(err)
	}
	return p
}

func mustHex(h string) []byte {
	b, err := hex.DecodeString(h)
	if err != nil {
		panic(err)
	}
	return b
}

func to32(t *testing.T, b []byte) *[32]byte {
	t.Helper()
	if len(b) != 32 {
		t.Fatalf("want 32 bytes, got %d", len(b))
	}
	return (*[32]byte)(b)
}

// readVectors reads a .vec file in Monocypher's format: hex values ending in
// ':', one per line, a blank line after each record of n values.
func readVectors(t *testing.T, name string, n int) [][][]byte {
	t.Helper()
	raw, err := os.ReadFile("testdata/" + name)
	if err != nil {
		t.Fatal(err)
	}
	var records [][][]byte
	for _, block := range strings.Split(strings.TrimSpace(string(raw)), "\n\n") {
		lines := strings.Split(block, "\n")
		if len(lines) != n {
			t.Fatalf("%s: record of %d lines, want %d: %q", name, len(lines), n, block)
		}
		var rec [][]byte
		for _, line := range lines {
			h, ok := strings.CutSuffix(line, ":")
			if !ok {
				t.Fatalf("%s: line %q does not end in ':'", name, line)
			}
			rec = append(rec, mustHex(h))
		}
		records = append(records, rec)
	}
	if len(records) == 0 {
		t.Fatalf("%s: no vectors", name)
	}
	return records
}

// The direct map against elligator-direct.py: representative, then u. The
// padding bits vary, so this also checks that the decoder ignores them.
func TestMonocypherMap(t *testing.T) {
	for i, rec := range readVectors(t, "elligator_dir.vec", 2) {
		var pub [32]byte
		RepresentativeToPublicKey(&pub, to32(t, rec[0]))
		if !bytes.Equal(pub[:], rec[1]) {
			t.Errorf("vector %d: map(%x) = %x, want %x", i, rec[0], pub, rec[1])
		}
	}
}

// The inverse map against elligator-inverse.py: u, tweak, 00 or ff, then
// the representative.
func TestMonocypherRev(t *testing.T) {
	for i, rec := range readVectors(t, "elligator_inv.vec", 4) {
		want := rec[2][0] == 0x00
		var repr [32]byte
		if got := hide(&repr, to32(t, rec[0]), rec[1][0]); got != want {
			t.Errorf("vector %d: rev(%x, %02x) ok = %v, want %v", i, rec[0], rec[1][0], got, want)
			continue
		}
		if want && !bytes.Equal(repr[:], rec[3]) {
			t.Errorf("vector %d: rev(%x, %02x) = %x, want %x", i, rec[0], rec[1][0], repr, rec[3])
		}
	}
}

// Key pairs against testdata/gen/gen_keypair.py: secret key, tweak, 00 or
// ff, public key, representative.
func TestMonocypherKeyPair(t *testing.T) {
	for i, rec := range readVectors(t, "keypair.vec", 5) {
		priv, tweak, want := to32(t, rec[0]), rec[1][0], rec[2][0] == 0x00
		var dirty [32]byte
		dirtyPublicKey(&dirty, priv)
		if !bytes.Equal(dirty[:], rec[3]) {
			t.Errorf("vector %d: dirty public key %x, want %x", i, dirty, rec[3])
		}
		pub := bytes.Repeat([]byte{0xa5}, 32)
		repr := bytes.Repeat([]byte{0x5a}, 32)
		got := ScalarBaseMult((*[32]byte)(pub), (*[32]byte)(repr), priv, tweak)
		switch {
		case got != want:
			t.Errorf("vector %d: ok = %v, want %v", i, got, want)
		case want && (!bytes.Equal(pub, rec[3]) || !bytes.Equal(repr, rec[4])):
			t.Errorf("vector %d: got (%x, %x), want (%x, %x)", i, pub, repr, rec[3], rec[4])
		case !want && (!bytes.Equal(pub, bytes.Repeat([]byte{0xa5}, 32)) || !bytes.Equal(repr, bytes.Repeat([]byte{0x5a}, 32))):
			t.Errorf("vector %d: outputs written on failure", i)
		}
	}
}

// RFC 9380 appendix J.4: Q = map_to_curve(u) for curve25519_XMD:SHA-512_ELL2_NU_
// (J.4.2), and Q0, Q1 from u[0], u[1] for _RO_ (J.4.1). Values are big-endian
// as the RFC prints them. map(r) = map(-r), so a u above 2^254, which a
// representative cannot hold, is checked as p - u.
var rfc9380 = []struct{ u, x string }{
	// J.4.2, NU: u[0], Q.x
	{"608d892b641f0328523802a6603427c26e55e6f27e71a91a478148d45b5093cd", "51125222da5e763d97f3c10fcc92ea6860b9ccbbd2eb1285728f566721c1e65b"},
	{"46f5b22494bfeaa7f232cc8d054be68561af50230234d7d1d63d1d9abeca8da5", "7d56d1e08cb0ccb92baf069c18c49bb5a0dcd927eff8dcf75ca921ef7f3e6eeb"},
	{"235fe40c443766ce7e18111c33862d66c3b33267efa50d50f9e8e5d252a40aaa", "3fbe66b9c9883d79e8407150e7c2a1c8680bee496c62fabe4619a72b3cabe90f"},
	{"001e92a544463bda9bd04ddbe3d6eed248f82de32f522669efc5ddce95f46f5b", "227e0bb89de700385d19ec40e857db6e6a3e634b1c32962f370d26f84ff19683"},
	{"1a68a1af9f663592291af987203393f707305c7bac9c8d63d6a729bdc553dc19", "3bcd651ee54d5f7b6013898aab251ee8ecc0688166fce6e9548d38472f6bd196"},
	// J.4.1, RO: u[0], Q0.x and u[1], Q1.x
	{"005fe8a7b8fef0a16c105e6cadf5a6740b3365e18692a9c05bfbb4d97f645a6a", "36b4df0c864c64707cbf6cf36e9ee2c09a6cb93b28313c169be29561bb904f98"},
	{"1347edbec6a2b5d8c02e058819819bee177077c9d10a4ce165aab0fd0252261a", "3fa114783a505c0b2b2fbeef0102853c0b494e7757f2a089d0daae7ed9a0db2b"},
	{"49bed021c7a3748f09fa8cdfcac044089f7829d3531066ac9e74e0994e05bc7d", "16b3d86e056b7970fa00165f6f48d90b619ad618791661b7b5e1ec78be10eac1"},
	{"5c36525b663e63389d886105cee7ed712325d5a97e60e140aba7e2ce5ae851b6", "7ec29ddbf34539c40adfa98fcb39ec36368f47f30e8f888cc7e86f4d46e0c264"},
	{"6412b7485ba26d3d1b6c290a8e1435b2959f03721874939b21782df17323d160", "71de3dadfe268872326c35ac512164850860567aea0e7325e6b91a98f86533ad"},
	{"24c7b46c1c6d9a21d32f5707be1380ab82db1054fde82865d5c9e3d968f287b2", "5704069021f61e41779e2ba6b932268316d6d2a6f064f997a22fef16d1eaeaca"},
	{"5e123990f11bbb5586613ffabdb58d47f64bb5f2fa115f8ea8df0188e0c9e1b5", "7a94d45a198fb5daa381f45f2619ab279744efdd8bd8ed587fc5b65d6cea1df0"},
	{"5e8553eb00438a0bb1e7faa59dec6d8087f9c8011e5fb8ed9df31cb6c0d4ac19", "30506fb7a32136694abd61b6113770270debe593027a968a01f271e146e60c18"},
	{"20f481e85da7a3bf60ac0fb11ed1d0558fc6f941b3ac5469aa8b56ec883d6d7d", "02d606e2699b918ee36f2818f2bc5013e437e673c9f9b9cdc15fd0c5ee913970"},
	{"017d57fd257e9a78913999a23b52ca988157a81b09c5442501d07fed20869465", "38920e9b988d1ab7449c0fa9a6058192c0c797bb3d42ac345724341a1aa98745"},
}

func TestRFC9380(t *testing.T) {
	high := 0
	for i, v := range rfc9380 {
		u := new(big.Int).SetBytes(mustHex(v.u))
		if u.Cmp(two254) >= 0 {
			u.Sub(fieldP, u)
			high++
		}
		var repr, pub [32]byte
		u.FillBytes(repr[:])
		reverse(repr[:])
		want := mustHex(v.x)
		reverse(want)
		for pad := byte(0); pad < 4; pad++ {
			repr[31] = repr[31]&0x3f | pad<<6
			RepresentativeToPublicKey(&pub, &repr)
			if !bytes.Equal(pub[:], want) {
				t.Errorf("vector %d, padding %d: map = %x, want %x", i, pad, pub, want)
			}
		}
	}
	if high == 0 || high == len(rfc9380) {
		t.Fatalf("%d of %d u values above 2^254; want both kinds", high, len(rfc9380))
	}
}

func reverse(b []byte) {
	for i, j := 0, len(b)-1; i < j; i, j = i+1, j-1 {
		b[i], b[j] = b[j], b[i]
	}
}

// fill writes rng's output into b (ChaCha8.Read needs Go 1.23).
func fill(rng *rand.ChaCha8, b []byte) {
	var w [8]byte
	for i := 0; i < len(b); i += 8 {
		binary.LittleEndian.PutUint64(w[:], rng.Uint64())
		copy(b[i:], w[:])
	}
}

// keyPair draws a key pair the way obfs4's ntor.NewKeypair does: SHA-512 of
// 32 random bytes, the first half the private key, the last byte the tweak.
func keyPair(rng *rand.ChaCha8) (priv, pub, repr [32]byte, tweak byte) {
	for {
		var seed [32]byte
		fill(rng, seed[:])
		digest := sha512.Sum512(seed[:])
		copy(priv[:], digest[:32])
		tweak = digest[63]
		if ScalarBaseMult(&pub, &repr, &priv, tweak) {
			return
		}
	}
}

// choiceOf reads off the wire which of u's two representatives r is:
// 0 when r^2 = -u/(2(u+A)), the one for v >= 0, else 1.
func choiceOf(repr *[32]byte) int {
	var pub [32]byte
	RepresentativeToPublicKey(&pub, repr)
	masked := *repr
	masked[31] &= 0x3f
	r, _ := new(field.Element).SetBytes(masked[:])
	u, _ := new(field.Element).SetBytes(pub[:])
	lhs := new(field.Element).Square(r)
	lhs.Add(lhs, lhs)
	lhs.Multiply(lhs, new(field.Element).Add(u, feA))
	lhs.Add(lhs, u)
	return 1 - lhs.Equal(feZero)
}

// lowOrderOf returns L times the Edwards point the full Elligator 2 map
// (edwards25519-extra, as obfs4's ntor_test uses it) gives for repr: the
// key's low-order component, up to the sign of the point.
func lowOrderOf(repr *[32]byte) *edwards25519.Point {
	masked := *repr
	masked[31] &= 0x3f
	r, _ := new(field.Element).SetBytes(masked[:])
	p := elligator2.EdwardsFlavor(r)
	q := new(edwards25519.Point).ScalarMult(scMinus1, p)
	return q.Add(q, p)
}

func lowOrderMultiples() [8]*edwards25519.Point {
	var m [8]*edwards25519.Point
	m[0] = edwards25519.NewIdentityPoint()
	for k := 1; k < 8; k++ {
		m[k] = new(edwards25519.Point).Add(m[k-1], monocypherLop)
	}
	return m
}

func TestLowOrderPoint(t *testing.T) {
	m := lowOrderMultiples()
	for k := 1; k < 8; k++ {
		if m[k].Equal(m[0]) == 1 {
			t.Fatalf("%d * lop is the identity; want order 8", k)
		}
	}
	if new(edwards25519.Point).Add(m[7], monocypherLop).Equal(m[0]) != 1 {
		t.Fatal("8 * lop is not the identity")
	}
}

// u = -A is not on the curve (u^3 + A*u^2 + u = -A is not a square), so no
// public key reaches crypto_elligator_rev's one input that the paper
// excludes and Monocypher's fast path does not test for.
func TestMinusAIsNotOnCurve(t *testing.T) {
	minusA := new(big.Int).Sub(fieldP, big.NewInt(486662))
	if big.Jacobi(minusA, fieldP) != -1 {
		t.Fatal("-A is a square mod p")
	}
}

func TestRoundTripAndAgreement(t *testing.T) {
	rng := rand.NewChaCha8([32]byte{'r', 'o', 'u', 'n', 'd'})
	for i := 0; i < 1000; i++ {
		privA, pubA, reprA, tweakA := keyPair(rng)
		privB, pubB, _, _ := keyPair(rng)

		var again, againRepr [32]byte
		if !ScalarBaseMult(&again, &againRepr, &privA, tweakA) || again != pubA || againRepr != reprA {
			t.Fatal("ScalarBaseMult is not deterministic")
		}
		for pad := byte(0); pad < 4; pad++ {
			r := reprA
			r[31] = r[31]&0x3f | pad<<6
			var got [32]byte
			RepresentativeToPublicKey(&got, &r)
			if got != pubA {
				t.Fatalf("repr %x, padding %d: map = %x, want %x", reprA, pad, got, pubA)
			}
		}
		if reprA[31]>>6 != tweakA>>6 {
			t.Fatalf("padding %d, want tweak's top bits %d", reprA[31]>>6, tweakA>>6)
		}
		masked := reprA
		masked[31] &= 0x3f
		reverse(masked[:])
		if new(big.Int).SetBytes(masked[:]).Cmp(halfP) > 0 {
			t.Fatalf("representative %x is above (p-1)/2", reprA)
		}
		if choiceOf(&reprA) != int(tweakA&1) {
			t.Fatalf("representative choice %d, want tweak bit 0 = %d", choiceOf(&reprA), tweakA&1)
		}

		ab, err1 := curve25519.X25519(privA[:], pubB[:])
		ba, err2 := curve25519.X25519(privB[:], pubA[:])
		cleanB, err3 := curve25519.X25519(privB[:], curve25519.Basepoint)
		aClean, err4 := curve25519.X25519(privA[:], cleanB)
		if err1 != nil || err2 != nil || err3 != nil || err4 != nil {
			t.Fatal(err1, err2, err3, err4)
		}
		if !bytes.Equal(ab, ba) || !bytes.Equal(ab, aClean) {
			t.Fatalf("shared secrets differ: %x, %x, %x", ab, ba, aClean)
		}
	}
}

// Every point the map reaches has both representatives, each maps back to
// it, and the one picked by bit 0 of the tweak is r or -r for exactly one
// value of the bit.
func TestInverseOfMap(t *testing.T) {
	rng := rand.NewChaCha8([32]byte{'i', 'n', 'v'})
	for i := 0; i < 1000; i++ {
		var repr [32]byte
		fill(rng, repr[:])
		repr[31] &= 0x3f
		r := new(big.Int).SetBytes(reversed(repr[:]))
		if r.Cmp(halfP) > 0 {
			r.Sub(fieldP, r)
		}
		var pub [32]byte
		RepresentativeToPublicKey(&pub, &repr)
		matches := 0
		for bit := byte(0); bit < 2; bit++ {
			var back, pub2 [32]byte
			if !hide(&back, &pub, bit) {
				t.Fatalf("map(%x) = %x has no representative", repr, pub)
			}
			RepresentativeToPublicKey(&pub2, &back)
			if pub2 != pub {
				t.Fatalf("map(rev(%x)) = %x", pub, pub2)
			}
			if new(big.Int).SetBytes(reversed(back[:])).Cmp(r) == 0 {
				matches++
			}
		}
		if matches != 1 {
			t.Fatalf("map(%x): %d of the two representatives are |r|, want 1", repr, matches)
		}
	}
}

func reversed(b []byte) []byte {
	c := append([]byte(nil), b...)
	reverse(c)
	return c
}

// Over 20,000 key pairs drawn as obfs4 draws them, from a fixed seed so the
// result is the same on every run: the low-order component, the padding bits,
// the representative choice and every byte of the representative are as
// random as they should be. Bounds are at p = 1e-4 each.
func TestStatistics(t *testing.T) {
	const n = 20000
	rng := rand.NewChaCha8([32]byte{'s', 't', 'a', 't', 's'})
	m := lowOrderMultiples()
	var lowOrder [8]int
	var padding [4]int
	var bitOnes [256]int
	var byteCounts [32][256]int
	choiceOnes := 0
	for i := 0; i < n; i++ {
		priv, _, repr, _ := keyPair(rng)

		lo := lowOrderOf(&repr)
		k := int(priv[0]&7) * 5 % 8 // L = 5 mod 8
		found := -1
		for j := range m {
			if lo.Equal(m[j]) == 1 {
				found = j
			}
		}
		if found != k && found != (8-k)%8 {
			t.Fatalf("key %d: L times the key is %d*lop, want +-%d*lop (from the private key's low bits)", i, found, k)
		}
		lowOrder[found]++
		padding[repr[31]>>6]++
		choiceOnes += choiceOf(&repr)
		for b := 0; b < 256; b++ {
			bitOnes[b] += int(repr[b/8] >> (b % 8) & 1)
		}
		for j, v := range repr {
			byteCounts[j][v]++
		}
	}

	if x := chiSquare(lowOrder[:]); x > 29.88 { // 7 degrees of freedom
		t.Errorf("low-order components %v: chi-square %.1f", lowOrder, x)
	}
	if x := chiSquare(padding[:]); x > 21.11 { // 3 degrees of freedom
		t.Errorf("padding bits %v: chi-square %.1f", padding, x)
	}
	if z := zScore(choiceOnes, n); z > 3.89 {
		t.Errorf("second representative chosen %d of %d times: z = %.2f", choiceOnes, n, z)
	}
	for b, ones := range bitOnes {
		if z := zScore(ones, n); z > 3.89 {
			t.Errorf("representative bit %d set %d of %d times: z = %.2f", b, ones, n, z)
		}
	}
	for j := range byteCounts {
		if x := chiSquare(byteCounts[j][:]); x > 347.7 { // 255 degrees of freedom
			t.Errorf("representative byte %d: chi-square %.1f", j, x)
		}
	}
	t.Logf("low-order components %v, padding %v, second representative %d of %d", lowOrder, padding, choiceOnes, n)
}

// chiSquare tests counts against equal shares.
func chiSquare(counts []int) float64 {
	total := 0
	for _, c := range counts {
		total += c
	}
	want := float64(total) / float64(len(counts))
	x := 0.0
	for _, c := range counts {
		d := float64(c) - want
		x += d * d / want
	}
	return x
}

// zScore is |ones - n/2| in standard deviations of a fair coin.
func zScore(ones, n int) float64 {
	return math.Abs(float64(ones)-float64(n)/2) / (math.Sqrt(float64(n)) / 2)
}

func BenchmarkScalarBaseMult(b *testing.B) {
	rng := rand.NewChaCha8([32]byte{'b'})
	var priv, pub, repr [32]byte
	for i := 0; i < b.N; i++ {
		fill(rng, priv[:])
		ScalarBaseMult(&pub, &repr, &priv, priv[31])
	}
}

func BenchmarkRepresentativeToPublicKey(b *testing.B) {
	rng := rand.NewChaCha8([32]byte{'b'})
	var pub, repr [32]byte
	fill(rng, repr[:])
	for i := 0; i < b.N; i++ {
		RepresentativeToPublicKey(&pub, &repr)
	}
}
