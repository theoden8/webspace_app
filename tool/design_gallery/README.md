# Design gallery

Renders the app's real widgets in a browser so they can be looked at and
screenshotted. Design-time only: `web/` exists for this and nothing else, the
app is not shipped for web.

```bash
node tool/design_gallery/sync_fonts.js                                # once, after npm install
flutter build web -t lib/design_gallery/main.dart --no-web-resources-cdn
node tool/design_gallery/shoot.js                                     # -> build/design_cards/*.png
```

To browse by hand, serve `build/web` and open it: no query string lists every
card, `?card=<id>&theme=light|dark&accent=<name>&locale=<code>` renders one
card alone. Card ids are in `galleryCards` ([lib/design_gallery/main.dart](../../lib/design_gallery/main.dart)).

## Constraints

- **Flutter web paints into a canvas.** The HTML renderer was removed in 3.29,
  so there is no DOM to select per component. That is why single-card mode
  exists: one card fills the viewport and the viewport is the screenshot.
  Viewport sizes live in `shoot.js`, not in the Dart registry.
- **No WebView.** `flutter_inappwebview` has no usable web implementation here,
  so cards draw a placeholder where site content goes. The gallery is for the
  chrome around the content, not the content.
- **Fonts must be local.** CanvasKit fetches Roboto from fonts.gstatic.com and
  draws *no text at all* when that fails. `sync_fonts.js` copies Roboto out of
  the pinned `@expo-google-fonts/roboto` dev dependency into `web/fonts/`
  (gitignored, regenerate it rather than committing font binaries) and the
  gallery registers it via `FontLoader` before `runApp`.
- **Only widgets that compile for web can appear.** Anything reaching
  `dart:io` or `dart:ffi` is out. Today that funnels through
  `lib/services/webview.dart` -> `content_blocker_service.dart` ->
  `adblock_engine.dart` (`dart:ffi`) and `camera_permission_service.dart`
  (`dart:io`), which is what keeps most of `lib/widgets/` out of the gallery.
  Splitting those data surfaces from their platform surfaces is what unlocks
  more cards.

## Adding a card

Add a `GalleryCard` to `galleryCards`, then add its id and viewport to `CARDS`
in `shoot.js`. Prefer composing the real widget over redrawing it; a card that
reimplements a widget stops being evidence of anything.
