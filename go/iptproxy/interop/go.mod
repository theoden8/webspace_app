module webspace.local/interop

go 1.26.0

require (
	gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/goptlib v1.6.0
	gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird v0.0.0-20260115133752-0b10edbb61e0
)

require (
	github.com/andybalholm/brotli v1.3.0 // indirect
	github.com/dchest/siphash v1.2.3 // indirect
	github.com/klauspost/compress v1.20.5 // indirect
	github.com/refraction-networking/utls v1.8.2 // indirect
	golang.org/x/crypto v0.59.0 // indirect
	golang.org/x/net v0.63.0 // indirect
	golang.org/x/sys v0.50.0 // indirect
	golang.org/x/text v0.44.0 // indirect
	webspace.local/hiddenkey v0.0.0-00010101000000-000000000000 // indirect
)

// The trees go/iptproxy/build.sh prepares: lyrebird less its GPL parts, its
// handshake over hiddenkey and meek_lite's round tripper go/meekutls's, as the
// framework compiles them.
replace gitlab.torproject.org/tpo/anti-censorship/pluggable-transports/lyrebird => ../build/src/lyrebird

replace webspace.local/hiddenkey => ../build/src/hiddenkey
