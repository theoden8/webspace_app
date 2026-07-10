## Why

Opening the add-site suggestions list fires favicon requests to third parties (DuckDuckGo, Google) for every tile, on first launch, before the user has chosen anything. This is why the fdroid flavor ships an empty suggestions default (`configurable-suggested-sites`): shipping the curated list there would mean the app reaches out to Google/DDG just for browsing suggestions, which is exactly the third-party contact F-Droid users object to. Bundling the curated icons and rendering the list through a network-free read path removes that contact, which in turn lets fmain and fdroid ship the same suggestions defaults.

## What Changes

- Add a **network-free icon read path** the suggestions list uses to render tiles. It consults bundled assets + in-memory cache + persisted disk cache only, never reaches the outbound HTTP factory, and emits a placeholder on a miss instead of fetching.
- Keep the existing network-capable fetch path for the **add-suggestion action**: when a user adds a suggestion (or a custom site), the icon is fetched and stored, warming the shared cache. Viewing the list never fetches.
- **Bundle committed favicon assets** for the curated default suggestions, shipped in the APK, so the offline read path has data for sites the user never "added". Assets are committed (pinned), not fetched during `flutter build` (build-time fetch would break reproducible builds and just move the third-party contact to the build server).
- **Reconcile fmain and fdroid suggestions defaults**: once the list makes zero network calls, fdroid ships the same curated default suggestions as fmain instead of an empty list.
- Add a regression **test asserting the suggestions list makes zero outbound icon requests** (the recording `OutboundHttpFactory` is never asked for a client while rendering the curated set).
- Add a developer-run **regeneration script** for the bundled icon assets (refreshes the committed assets; not part of the build).

## Capabilities

### New Capabilities
<!-- None. This extends two existing capabilities. -->

### Modified Capabilities
- `icon-fetching`: add an offline (bundled + cache only) read mode that never contacts the outbound HTTP factory and resolves to a placeholder on miss; define the shared-cache invariant so add-time fetches are visible to offline reads in-session.
- `configurable-suggested-sites`: curated default suggestions render through the offline read path backed by committed bundled icon assets; fdroid and fmain ship identical suggestions defaults; the no-network guarantee for the suggestions list becomes a requirement.

## Impact

- `lib/services/icon_service.dart` — new offline read entry point alongside the existing top-level fetch functions; shared module-level caches stay the single source so add-time writes are visible to offline reads.
- `lib/services/suggested_sites_service.dart:40-41` — `flavorDefaultSuggestions` no longer branches on fdroid.
- `lib/screens/add_site.dart` — `UnifiedFaviconImage` / suggestions grid tiles call the offline read path; the add action keeps the network path.
- New committed assets under `assets/suggested_icons/` + `pubspec.yaml` asset registration + a regeneration script under `scripts/`.
- Tests: new zero-network assertion reusing the `RecordingFactory` pattern from `test/outbound_http_call_sites_test.dart`; `test/suggested_sites_test.dart` flavor expectation updated.
- No change to the outbound HTTP factory, proxy routing, or `OutboundClientBlocked` semantics (offline is a distinct concept from fail-closed-blocked).
