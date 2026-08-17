# Design gallery

Renders the app's real widgets in a browser so the UI can be looked at,
iterated on, and screenshotted. Design-time only: `web/` exists for this and
nothing else, the app is not shipped for web, and the WebView does not run
there.

Entrypoint [lib/design_gallery/main.dart](../../lib/design_gallery/main.dart)
(card registry), driver `shoot.js` (viewports, screenshots).

## Setup

```bash
npm install
fvm flutter pub get
npm run design:fonts        # copies Roboto into web/fonts/ (gitignored)
```

## Iterating

```bash
fvm flutter run -d web-server --web-port 8110 -t lib/design_gallery/main.dart
```

Serves at <http://127.0.0.1:8110>; `r` hot reloads, `R` hot restarts. Edit a
widget under `lib/`, press `r`, look. Append
`?card=<id>&theme=light|dark&accent=<name>&locale=<code>` to isolate one card
under one configuration; with no query string the page lists every card.

## Capturing

```bash
fvm flutter build web -t lib/design_gallery/main.dart --no-web-resources-cdn
npm run design:cards        # -> build/design_cards/<id>__<theme>[__<accent>].png
```

Cards, themes and the accent sweep are the three lists at the top of
`shoot.js`. Exit code is non-zero on unexpected page errors, so this is
CI-safe.

## Four things that break it silently

1. **`--no-web-resources-cdn` is required.** Without it CanvasKit is fetched
   from gstatic.com at runtime; where that is unreachable the page loads,
   boots nothing, and shows an empty document with no visible error.
2. **Fonts must be local.** CanvasKit pulls Roboto from fonts.gstatic.com and
   draws *no text at all* when that fails, not a fallback face. `sync_fonts.js`
   copies it out of the pinned `@expo-google-fonts/roboto` dev dependency and
   the gallery registers it with `FontLoader` before `runApp`. Never commit the
   font binaries; regenerate them.
3. **Flutter web paints into a canvas.** The HTML renderer was removed in 3.29,
   so there is no DOM to select per component. Hence single-card mode: one card
   fills the viewport and the viewport is the screenshot. Viewport sizes live
   in `shoot.js`, not in the Dart registry.
4. **No WebView.** `flutter_inappwebview` does not render here. Cards draw a
   placeholder where site content goes; the gallery is for the chrome around
   the content.

## Which widgets can appear

```bash
npm run design:check        # web_clean.js
```

Only files whose transitive imports avoid `dart:io` and `dart:ffi` compile for
web. 7 of 24 qualify today. The blockers are concentrated:

- `lib/web_view_model.dart:3` and `lib/services/webview.dart:3` import
  `dart:io` directly, which takes out most of `lib/widgets/` in one hop
- `lib/services/adblock_engine.dart` imports `dart:ffi`, reached through
  `content_blocker_service.dart`
- leaf services with their own `dart:io`: `clearurl_service`,
  `trusted_hosts_service`, `current_location_service`,
  `camera_permission_service`

Splitting the pure-data surface of those hubs from their platform surface is
what unlocks the real screens. That is the same engine/rendering separation the
root CLAUDE.md asks for, so it is worth doing on its own merits.

## Adding a card

1. Add a `GalleryCard` to `galleryCards` in `lib/design_gallery/main.dart`.
2. Add its id and viewport to `CARDS` in `shoot.js`.
3. Compose the real widget. A card that redraws a widget by hand is evidence of
   nothing and will drift; if the widget cannot be imported, fix the import
   chain instead of approximating it.

`browser-chrome` is the current exception and should be treated with suspicion:
its `UrlBar` and `TabBarCornerButton` are real, its app bar is an approximation
because the real one lives inside `main.dart`.

## Rules

- Nothing under `lib/` may import the gallery. The dependency runs one way:
  gallery imports app code.
- App code shared with the gallery goes in a normal app file, not a
  design-only one. `lib/theme/accent_theme.dart` is app code that the gallery
  happens to read, which is why the color cards are trustworthy.
- Do not add the web target to release builds or CI release workflows.
- Design flows one way. Nothing in a browser, a screenshot, or a Claude Design
  project writes back into Dart; changes are made by editing widgets and
  re-running the loop above.
