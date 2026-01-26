# OpenSpec - WebSpace App Specifications

This directory contains spec-driven documentation for the WebSpace app features using the [OpenSpec](https://github.com/Fission-AI/OpenSpec) format.

## Structure

```
openspec/
├── config.yaml                    # Project configuration
├── README.md                      # This file
└── specs/                         # Feature specifications
    ├── webspaces/spec.md          # Organize sites into workspaces
    ├── proxy/spec.md              # HTTP/HTTPS/SOCKS5 proxy configuration
    ├── site-editing/spec.md       # Edit site details and page titles
    ├── theme-preference/spec.md   # Dark/light mode for webviews
    ├── nested-url-blocking/spec.md # Block tracking and popup URLs
    ├── cookie-secure-storage/spec.md # Encrypted cookie storage
    ├── icon-fetching/spec.md      # Progressive favicon loading
    ├── settings-backup/spec.md    # Import/export settings
    ├── screenshots/spec.md        # Automated screenshot generation
    ├── demo-mode/spec.md          # Demo data seeding with user data preservation
    └── platform-support/spec.md   # Platform abstraction layer
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
| Webspaces | Completed | Organize sites into workspaces |
| Proxy | Completed | Per-site proxy configuration (Android/iOS) |
| Site Editing | Completed | Edit URLs and custom names |
| Theme Preference | Completed | Dark/light mode injection |
| Nested URL Blocking | Completed | Block trackers and popups |
| Cookie Secure Storage | Completed | Encrypted cookie storage |
| Icon Fetching | Completed | Progressive favicon loading |
| Settings Backup | Completed | Import/export JSON backups |
| Screenshots | Completed | Fastlane integration tests |
| Demo Mode | Completed | Demo data seeding with user data preservation |
| Platform Support | Completed | iOS, Android, macOS supported |

## Original Transcripts

The original feature documentation is preserved in `transcript/` directory. These OpenSpec files provide a more structured format suitable for AI-assisted development.

## Usage

These specs can be used with Claude Code, Cursor, and other AI coding assistants that support OpenSpec workflows.

For more information about OpenSpec, see: https://github.com/Fission-AI/OpenSpec
