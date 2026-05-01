# OpenSpec - WebSpace App Specifications

This directory contains spec-driven documentation for the WebSpace app features using the [OpenSpec](https://github.com/Fission-AI/OpenSpec) format.

## Structure

```
openspec/
├── config.yaml                           # Project configuration
├── README.md                             # This file
├── changes/                              # In-progress changes
└── specs/                                # Feature specifications
    ├── captcha-support/spec.md           # CAPTCHA detection and handling
    ├── clearurls/spec.md                 # ClearURLs tracking parameter removal
    ├── configurable-suggested-sites/spec.md # Configurable suggested sites list
    ├── content-blocker/spec.md           # ABP filter list content blocking
    ├── cookie-secure-storage/spec.md     # Encrypted cookie storage
    ├── developer-tools/spec.md           # In-app dev tools (JS console, cookie inspector)
    ├── dns-blocklist/spec.md             # Hagezi DNS blocklist domain blocking
    ├── external-scheme-handling/spec.md  # intent:// auto-resolve to http(s) fallback; prompt unresolvable schemes
    ├── home-shortcut/spec.md             # Android home screen shortcuts
    ├── icon-fetching/spec.md             # Progressive favicon loading
    ├── language/spec.md                  # Per-site language (Accept-Language + navigator.language override)
    ├── lazy-webview-loading/spec.md      # On-demand webview creation
    ├── localcdn/spec.md                  # Local CDN resource caching
    ├── navigation/spec.md                # Back gesture, home button, pull-to-refresh
    ├── nested-url-blocking/spec.md       # Block tracking and popup URLs
    ├── per-site-cookie-isolation/spec.md # Cookie isolation via domain conflict detection
    ├── platform-support/spec.md          # Platform abstraction layer
    ├── proxy/spec.md                     # HTTP/HTTPS/SOCKS5 proxy configuration
    ├── proxy-password-secure-storage/spec.md # Encrypted proxy passwords; stripped from exports
    ├── screenshots/spec.md               # Automated screenshot generation
    ├── settings-backup/spec.md           # Import/export settings
    ├── site-editing/spec.md              # Edit site details and page titles
    ├── user-scripts/spec.md              # Per-site custom JavaScript injection
    ├── webspaces/spec.md                 # Organize sites into workspaces
    └── webview-hints/spec.md             # Webview theme and display hints
```

## Specification Format

Each spec file follows the OpenSpec format:

1. **Overview**: Brief description of the feature
2. **Status**: Implementation status and date
3. **Requirements**: Normative behaviors using SHALL/MUST
4. **Scenarios**: Given/When/Then format for testable behaviors
5. **Data Models**: Key data structures
6. **Files**: Created and modified files

## Quick Reference

| Feature | Status | Description |
|---------|--------|-------------|
| Captcha Support | Completed | CAPTCHA detection and handling |
| ClearURLs | Completed | Tracking parameter removal with per-site toggle |
| Configurable Suggested Sites | Completed | Configurable suggested sites list with empty default for fdroid |
| Content Blocker | Completed | ABP filter list content blocking (domain, CSS, text-based) |
| Cookie Secure Storage | Completed | Encrypted cookie persistence with flutter_secure_storage |
| Developer Tools | Completed | JS console, cookie inspector, HTML export, app logs |
| DNS Blocklist | Completed | Hagezi DNS blocklist with severity levels and per-site toggle |
| External Scheme Handling | Completed | intent:// fallback URLs route through standard navigation; prompt only when no http(s) equivalent exists |
| Home Shortcut | Completed | Android home screen shortcut via pinned shortcuts API |
| Icon Fetching | Completed | Progressive favicon loading with fallbacks |
| Language | Completed | Per-site language via Accept-Language header and navigator.language override |
| Lazy Webview Loading | Completed | On-demand webview creation with IndexedStack placeholders |
| LocalCDN | Completed | Cache CDN resources locally to prevent CDN tracking (Android) |
| Navigation | Completed | Back gesture, home button, drawer swipe, pull-to-refresh |
| Nested URL Blocking | Completed | Cross-domain navigation control and auto-redirect blocking |
| Per-Site Cookie Isolation | Completed | Cookie isolation via domain conflict detection |
| Platform Support | Completed | iOS, Android, macOS supported |
| Proxy | Completed | Per-site HTTP/HTTPS/SOCKS5 proxy (Android only) |
| Screenshots | Completed | Automated screenshot generation via integration tests |
| Settings Backup | Completed | JSON import/export of all settings |
| Site Editing | Completed | Edit URLs and custom names |
| User Scripts | Completed | Per-site custom JavaScript injection with timing control |
| Webspaces | Completed | Organize sites into named collections |
| Webview Hints | Completed | Webview theme hints (color-scheme, matchMedia, HTML cache theme prelude) |

## Usage

These specs can be used with Claude Code, Cursor, and other AI coding assistants that support OpenSpec workflows.

For more information about OpenSpec, see: https://github.com/Fission-AI/OpenSpec
