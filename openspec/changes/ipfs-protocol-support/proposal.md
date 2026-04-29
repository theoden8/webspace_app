# Change: IPFS Protocol Support

## Summary

Add `ipfs://` and `ipns://` URL scheme support to WebSpace via HTTP gateway rewriting. When a user enters or navigates to an IPFS/IPNS URL, the app transparently rewrites it to a configurable IPFS HTTP gateway (default: `https://ipfs.io`). The URL bar displays the original `ipfs://` / `ipns://` URL for clarity.

## Motivation

IPFS (InterPlanetary File System) is a decentralized content-addressed protocol gaining adoption for hosting websites, documentation, and dApps. Many users who care about privacy and decentralization (WebSpace's target audience) want to access IPFS content without installing a full IPFS node. Gateway-based access is the pragmatic first step — it's how Brave browser started IPFS support.

## Approach: Gateway Proxy

Intercept `ipfs://` and `ipns://` URLs and rewrite them to an HTTP gateway URL before loading in the webview. This avoids any native IPFS dependencies while providing useful access to the IPFS network.

### URL Rewriting Rules

| Input | Rewritten |
|-------|-----------|
| `ipfs://<CID>` | `https://ipfs.io/ipfs/<CID>` |
| `ipfs://<CID>/path/to/file` | `https://ipfs.io/ipfs/<CID>/path/to/file` |
| `ipns://<name>` | `https://ipfs.io/ipns/<name>` |
| `ipns://<name>/path` | `https://ipfs.io/ipns/<name>/path` |

The gateway base URL (`https://ipfs.io`) is user-configurable in app settings.

## Requirements

### REQ-IPFS-001: Recognize IPFS/IPNS URL Schemes

The system SHALL accept `ipfs://` and `ipns://` URLs in:
- Add Site screen URL input
- URL bar text submission
- Site editing dialog

When these schemes are detected, the system SHALL NOT prepend `https://`.

### REQ-IPFS-002: Gateway URL Rewriting

The system SHALL rewrite IPFS/IPNS URLs to HTTP gateway URLs before loading in the webview:
- Extract the CID or IPNS name and path from the original URL
- Construct `<gateway>/ipfs/<CID>[/path]` or `<gateway>/ipns/<name>[/path]`
- Load the rewritten URL in the webview

### REQ-IPFS-003: URL Bar Display

The URL bar SHALL display the original `ipfs://` or `ipns://` URL (not the gateway-rewritten URL) when the user is viewing IPFS content. A distinct icon or indicator SHOULD show that the content is loaded via IPFS gateway.

### REQ-IPFS-004: Navigation Interception

When a user clicks an `ipfs://` or `ipns://` link within a loaded page, `shouldOverrideUrlLoading` SHALL intercept it and apply gateway rewriting, rather than blocking or opening externally.

### REQ-IPFS-005: Skip DNS Validation for IPFS URLs

The Add Site preview/validation SHALL skip DNS lookup for `ipfs://` and `ipns://` URLs, since the CID/name is not a DNS hostname.

### REQ-IPFS-006: Configurable Gateway

The app SHALL provide a setting for the IPFS gateway base URL:
- Default: `https://ipfs.io`
- Common alternatives: `https://dweb.link`, `https://cloudflare-ipfs.com`, `https://gateway.pinata.cloud`
- Setting is global (not per-site)
- Persisted via SharedPreferences

### REQ-IPFS-007: Domain Comparison Exemption

IPFS/IPNS URLs SHALL be exempted from the normal domain-comparison logic used for cookie isolation and nested webview decisions, since they don't have traditional hostnames.

## Affected Files

| File | Change |
|------|--------|
| `lib/screens/add_site.dart` | Accept `ipfs://`, `ipns://` schemes; skip DNS validation |
| `lib/widgets/url_bar.dart` | Accept schemes; display original URL; IPFS indicator |
| `lib/services/webview.dart` | `_shouldBlockUrl` exemption; navigation interception with rewriting |
| `lib/web_view_model.dart` | Domain comparison exemption; store original vs rewritten URL |
| `lib/main.dart` | Settings UI for gateway URL; pass gateway config |
| `lib/services/ipfs_service.dart` | **New** - URL detection, rewriting, gateway config |
| `lib/screens/settings.dart` | Gateway URL preference field |

## Out of Scope

- Running an embedded IPFS node (future enhancement)
- Offline/P2P content resolution
- IPFS pinning or publishing
- CID validation (trust the gateway to reject invalid CIDs)

## Risks & Mitigations

| Risk | Mitigation |
|------|-----------|
| Gateway goes down | User can switch to alternative gateway in settings |
| Gateway censors content | Multiple gateway options; user can self-host |
| ClearURLs/DNS blocklist interfere | Skip these filters for gateway-rewritten IPFS URLs |
| Cookie isolation confusion | IPFS sites keyed by CID, not gateway domain |
