# IP Leakage Coverage

## MODIFIED Requirements

### Requirement: LEAK-007 - Coverage matrix

The proxy-coverage matrix below SHALL be kept in sync with the
implementation. Adding a new outbound seam without registering it here is a
spec violation.

| Category | Trigger | Proxy applied | Implementation |
|---|---|---|---|
| Webview navigation (HTTP/HTTPS/CONNECT) | Site load, in-page request | Per-site (DEFAULT → global) | `ProxyManager.setProxySettings`, `lib/services/webview.dart:164` |
| Webview WebRTC | RTCPeerConnection / STUN | Per-site `webRtcPolicy`, raised to relay only behind a proxy under Tracking Protection (ETP-031) | `lib/services/location_spoof_service.dart`, `WebViewModel.effectiveWebRtcPolicy` |
| Favicon: FaviconFinder, SVG body | `getFaviconUrl(Stream)`, `getSvgContent`, `FaviconFinder.getAll` | Per-site (DEFAULT → global) | `lib/services/icon_service.dart`, `lib/third_party/favicon/favicon.dart` |
| Favicon raster render | Drawer / tab strip / site list paints an icon | Per-site (DEFAULT → global) | `getIconBytes` in `lib/services/icon_service.dart`, `lib/screens/favicon_image_io.dart` |
| Per-site downloads (HTTP/HTTPS) | `onDownloadStartRequest` | Per-site (DEFAULT → global) | `DownloadEngine`, `lib/services/webview.dart:_handleHttpDownload` |
| User-script remote fetches | `__ws_s_*` / `__ws_f_*` JS handlers | Per-site (DEFAULT → global) | `lib/services/user_script_service.dart` |
| User-script URL-source download | Saving a script with a URL in the editor | Per-site (DEFAULT → global) | `fetchUserScriptSource`, `lib/screens/user_scripts.dart` |
| OSM tile fetches | Location-picker "Load map" | Global only | `lib/screens/location_picker.dart` |
| ClearURLs rules download | "Update ClearURLs rules" | Global only | `ClearUrlService.downloadRules` |
| DNS blocklist download | "Update DNS blocklist" | Global only | `DnsBlockService.downloadList` |
| Content-blocker list download | "Update content-blocker list" | Global only | `ContentBlockerService.downloadList` |
| LocalCDN catalog download | LocalCDN cache populate | Global only | `LocalCdnService._downloadAndCache` |
| Timezone polygon dataset download | "Download timezone data" | Global only | `TimezoneLocationService.download` |
| Web Push channel (Android, `web-push`) | A site the user allowed (WEBPUSH-003) is pushed to | None: the distributor app holds the connection from the device's own IP, and the site's server learns the push server's address; offered only by the user's explicit per-site permission, whose prompt says so | the distributor app, outside WebSpace; WebSpace's own delivery of a push loads the site under its posture (WEBPUSH-005) |

#### Scenario: New outbound code path

**Given** a developer adds a new Dart-side `http.get(...)` somewhere in `lib/`
**Then** the code review process SHALL fail until either:
  - the call is rerouted through `outboundHttp.clientFor(...)` with the
    appropriate per-site or global proxy, **or**
  - the spec's coverage matrix gains a row justifying why the call is
    exempt (e.g. localhost-only, app-bundle resource fetch)

#### Scenario: The matrix is checked by machine, not only by review

**Given** the Linux integration tier running under the deny-by-default
egress guard ([INTEG-016](../../../../specs/integration-tests/spec.md))
**When** any scenario reaches a destination outside loopback that
[`scripts/egress_allowlist.txt`](../../../../../scripts/egress_allowlist.txt)
does not cover
**Then** the run records the host and, in `enforce` mode, fails
**And** the three outcomes above are the three ways to clear it — route it
through the seam, point it at a loopback fixture, or add an argued
allowlist entry alongside the matrix row
