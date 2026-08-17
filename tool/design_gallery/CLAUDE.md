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
`shoot.js`. Exit code is non-zero on unexpected page errors or on a card that
drew (almost) nothing, so this is CI-safe.

## What is gated

- **Blank cards** (`shoot.js`): every card must clear 1% ink and 12 distinct
  colours, against a measured floor of 2.1% / 38. This is the only check that
  can see a correct widget tree rendering an empty frame; drop `web/fonts/` and
  `type-scale` falls to 0% ink. A card that trips it retries once before
  failing.
- **Registry drift** ([test/js/design_gallery_registry.test.js](../../test/js/design_gallery_registry.test.js)):
  card ids in Dart and viewport ids in `shoot.js` must agree, or a card is
  silently never shot. Runs in `npm run test:js`.
- **Accent contrast** ([test/accent_theme_contrast_test.dart](../../test/accent_theme_contrast_test.dart)):
  every role pair in `buildAccentColorScheme` holds 4.5:1 across all 8 accents
  and both brightnesses. Plain `flutter test`, no browser.

Structural questions ("does the button still exist") belong in widget tests and
`integration_test/`, not here. Pixel diffing the cards is deliberately not
done: cross-version rasterisation noise buries the real changes.

## Publishing to Claude Design

```bash
node tool/design_gallery/bundle.js     # build/design_bundle/**.html, cards embedded as data URIs
```

Then upload with the `DesignSync` tool: `finalize_plan` over the eight paths
with `localDir` set to `build/design_bundle`, then `write_files`. The project
is **WebSpace**, `130d2902-baca-4e8a-8d7d-237974bd429d`; pass that projectId or
the upload creates a second project instead of updating this one. Only the
maintainer's account can write to it.

Pages carry a first-line `<!-- @dsCard group="..." -->` marker, which is what
the Design System pane indexes; groups are Foundations and Components. The
bundle is a derivative of `build/design_cards` and is regenerated, never
edited by hand.

Publishing is one-way. Nothing in the design project feeds back into `lib/`.

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

## Screen cards

A card with `fullBleed: true` is a whole screen: it brings its own `Scaffold`,
renders unpadded in single-card mode, and gets a phone-sized frame on the index
page. `user-scripts` is the working example, hosting the real
`UserScriptsScreen` against local state. At the dev-server URL it is genuinely
interactive: the FAB pushes the real `UserScriptEditScreen`, tiles toggle,
delete confirms.

Adding another screen is gated on that screen compiling for web
(`npm run design:check`), not on the gallery. The drawer and site grid are
widgets inside `main.dart`, so they need that file to compile before they can
appear here at all.

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
