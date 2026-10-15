#!/usr/bin/env bash
# Readies a CI macOS runner for a debug build of the app: opens the login
# keychain flutter_secure_storage talks to, and gives the debug build the
# stock Flutter entitlements plus the network server and client the
# integration servers and the Tor runtime use. CI has no signing identity, so
# an ad-hoc signature cannot back the committed file's team-prefixed groups
# and taskgated SIGKILLs the app at launch; the comment on the macOS test
# tier in .github/workflows/build-and-test.yml has the whole account.
#
# CI only: it overwrites macos/Runner/DebugProfile.entitlements in the
# checkout. Run by the macOS test tier and the macOS screenshots.
set -x
security unlock-keychain -p "" "$HOME/Library/Keychains/login.keychain-db" || true
cat > macos/Runner/DebugProfile.entitlements <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>com.apple.security.app-sandbox</key>
	<true/>
	<key>com.apple.security.cs.allow-jit</key>
	<true/>
	<key>com.apple.security.files.user-selected.read-write</key>
	<true/>
	<key>com.apple.security.network.server</key>
	<true/>
	<key>com.apple.security.network.client</key>
	<true/>
</dict>
</plist>
EOF
