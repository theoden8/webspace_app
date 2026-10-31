# BUG-041 — A site's icon stays a globe where it stays drawn

Status: **open.** Each step of an icon's fetch now hands its success to every
icon of the site on screen, and an icon whose step failed asks again when Tor
comes up or the app comes back to the front; the network coming back while
the app stays in front is not one of those moments.

**Spec:** [icon-fetching](../../openspec/specs/icon-fetching/spec.md) ICON-017
**Tests:** `test/favicon_found_test.dart`, `test/icon_app_test.dart`

## Symptom

On the library home a folder's preview shows the globe for a site whose tile,
inside the opened folder, shows its icon. Closing the folder leaves the
preview as it was.

## Root mechanism

Every `UnifiedFaviconImage` runs the icon's steps once, as it mounts: the
search for the icon's URL (skipped when a past launch kept the URL), then the
fetch of its image or SVG body. A step's success lands in a process cache the
next widget reads as it mounts; a step's failure stays in the widget that met
it. The home's previews mount at launch, often before the network or the
site's proxy or Tor is up, and stay mounted; the folder's tiles mount each time
it opens. So the tile reads what the preview missed, and nothing tells the
preview. The fact is one, the site's icon, and each step's result has to reach
every widget drawing it, not only the ones mounted after it.

## Fix attempts

1. **2026-10-30 (#860, d228317c).** `getFaviconUrlStream` announces a site
   whose icon a search found (`faviconsFound`), and an icon with no URL and no
   search running loads again from the cache; a search that ends with nothing
   no longer overwrites an icon another search found while it ran. *Why:* the
   preview's search failed offline and the tile's later search succeeded.
   *Why partial:* it covered the search only. After the first launch a site's
   icon URL is kept on disk but its image is not, so a preview knows the URL,
   skips the search, and fails at the image instead, which no event reached.
2. **2026-10-30 (#869).** `getIconBytes` and `getSvgContent` announce an icon URL
   whose image or SVG body arrived (`iconImagesFetched`), and an icon whose own
   fetch of that URL failed draws it afresh from the cache; a fetch that ends
   with nothing returns what another fetch brought while it ran. *Why:* the
   reported preview had the URL and lacked only the image. *Why partial:* see
   below.

3. **2026-10-30 (#869).** An icon whose search or image came back with
   nothing asks again when Tor comes up (`SiteNetworkController`) and when the
   app comes back to the front (`AppLifecycleController`), through
   `retryFailedIcons`. *Why:* a preview of a folder never opened had nothing
   to learn from, and the usual cause at launch is Tor still bootstrapping or
   the network not yet up. *Why partial:* see below.

## Known open gaps

- The app has no event for the network coming back, so an icon that failed
  offline, while the app stays in front and its site is not on Tor, waits for
  the app to leave and come back.
- An image that arrives but does not decode is not fetched again.
