<div align="center">

<img src="assets/featureGraphic.jpg" alt="WebSpace Feature Graphic" width="100%"/>

---

[![Release](https://img.shields.io/github/v/release/theoden8/webspace_app)](https://github.com/theoden8/webspace_app/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/theoden8/webspace_app/total)](https://github.com/theoden8/webspace_app/releases)
[![Build and Test](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml/badge.svg)](https://github.com/theoden8/webspace_app/actions/workflows/build-and-test.yml)
<a href="https://github.com/sponsors/theoden8">
  <img src="https://img.shields.io/badge/Sponsor-theoden8-ff69b4" alt="Sponsor theoden8">
</a>

<a href="https://f-droid.org/packages/org.codeberg.theoden8.webspace">
  <img src="https://f-droid.org/badge/get-it-on.png" alt="Get it on F-Droid" height="80" align="middle">
</a>
<a href="https://apps.apple.com/app/webspace-app/id6758049523">
  <img src="https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg" alt="Download on the App Store" width="170" align="middle">
</a>
&nbsp;&nbsp;
<a href="https://play.google.com/store/apps/details?id=org.codeberg.theoden8.webspace">
  <img src="https://upload.wikimedia.org/wikipedia/commons/7/78/Google_Play_Store_badge_EN.svg" alt="Get it on Google Play" height="68" align="middle">
</a>

</div>

## Overview

WebSpace is a mobile app that brings all your favorite websites and web apps together in one organized, streamlined interface.

## Screenshots

<p align="center">
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/1.jpg" width="23%" alt="All Sites"/>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/2.jpg" width="23%" alt="Sites Drawer"/>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/3.jpg" width="23%" alt="Work Webspace"/>
  <img src="fastlane/metadata/android/en-US/images/phoneScreenshots/4.jpg" width="23%" alt="Workspace Sites"/>
</p>

**Features**

- 📱 Organize sites into multiple webspaces
- 🔒 Per-site cookie isolation with secure storage
- 🌍 Per-site language preferences (30+ languages)
- 💾 Import/export settings for backup
- 🔄 Proxy support with authentication (Android, iOS 17+, macOS 14+, Linux)
- 🧹 Tracking parameter removal via [ClearURLs](https://github.com/ClearURLs/Rules) rules (LGPL-3.0)
- 🛡️ DNS-level domain blocking via [Hagezi](https://github.com/hagezi/dns-blocklists) blocklists (GPL-3.0, 5 severity levels)
- 🚫 Ad & tracker filtering via [EasyList](https://easylist.to/) filter lists (GPL-3.0 / CC BY-SA 3.0), including EasyList, EasyPrivacy, Fanboy's Social Blocking List, and Fanboy's Annoyance List
- 📦 LocalCDN - cache CDN resources locally to prevent tracking (Android)
- 📌 Home screen shortcuts for quick site access (Android)
- 📜 Per-site user scripts (custom JavaScript injection)
- 🎨 Light/dark mode with accent colors

## Development

### Prerequisites
- [FVM](https://fvm.app/) (Flutter Version Manager)
- Xcode (for iOS/macOS)
- Android SDK (for Android)

### Setup
```bash
git clone https://github.com/theoden8/webspace_app
cd webspace_app

# Install Flutter version via FVM
fvm install

# Get dependencies
fvm flutter pub get
```

### Optional: Rust adblock engine

The content blocker can be backed by Brave's [adblock-rust](https://github.com/brave/adblock-rust) engine via `rust/webspace_adblock`. Off by default; opt in from App Settings → Content Blocker → "Use Rust adblock engine". Adds support for `$domain=`, regex network rules, generic class/id cosmetic lookups, and every other rule shape adblock-rust accepts.

The Rust crate auto-builds as part of the platform build:
- **Android** — Gradle `buildRustAdblock` task runs before `mergeJniLibFolders`. Requires `cargo` on PATH and `ANDROID_NDK_HOME` (or NDK installed under the SDK). Skip with `-PskipRustAdblock=true`.
- **Linux** — CMake `webspace_adblock_so` target runs before linking the runner.
- **iOS / macOS** — Xcode "Build adblock-rust" Run Script Phase added by the Pods post_install hook.

```bash
# Just build the app — the .so is built and bundled automatically.
fvm flutter build apk --flavor fdroid --release
fvm flutter build linux --release
fvm flutter build ipa --release
fvm flutter build macos --release

# Or invoke the script directly when you want to rebuild without the
# full Flutter build (e.g. iterating on rust/webspace_adblock/ alone):
./scripts/build_rust.sh linux         # or: android <abi> | android-all | ios | macos
```

Without `cargo` on PATH the Flutter build still succeeds — the Rust step prints a "skipping" notice and `AdblockEngine.load()` returns null at runtime, leaving the legacy Dart parser engine as the fallback.

Toggle the engine in the app, no rebuild required after the .so is bundled. Flipping the toggle off restores the legacy engine instantly.

## Platform Support

| Platform | Status | Purpose |
|----------|--------|---------|
| iOS | ✅ Supported | Target |
| Android | ✅ Supported | Target |
| macOS | ✅ Supported | Development |
| Linux | ✅ Supported | Development |

## License

This project is licensed under the [MIT License](LICENSE) - Copyright (c) 2023 Kirill Rodriguez.

**Assets**: Icons and images in the `assets/` directory are licensed under [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) - Copyright (c) Polina Levchenko. See [assets/LICENSE](assets/LICENSE) for details.
