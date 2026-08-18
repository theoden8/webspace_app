# WebSpace design project

This project is the design surface of a Flutter app. It is generated from the
app's repository and uploaded here; it does not generate itself, and nothing
here compiles.

## How the pipeline works

```
lib/**.dart          the app, and the only source of truth
  |                  scripts/design_web.sh app      -> build/web
  |                  tool/design_gallery/pack_app.js -> app/ in this project
  |                  scripts/design_web.sh gallery + shoot.js -> one PNG per card
  |                  tool/design_gallery/bundle.js  -> the pages you are reading
  v
this project         app/ (live), screens/, foundations/, components/, README.md
```

Every step runs in the app repository, on a machine with Flutter and Node.
This project is the last stop: it receives files, it never produces them. So
the flow is one-way, and there are exactly two ways to change what you see
here. Change the Dart and ask for a rebuild, or ask for a rebuild of what the
Dart already says. Editing a page here is neither.

## What is in it

- **Screens / Live app** iframes `app/index.html`: the real app running, on
  seeded demo data. Drawer, webspace switch, per-site settings, animations,
  all of it. Give it ~15 seconds on first load, it fetches a 12MB engine
  before the first frame. State persists in this browser's storage, so a
  layout that looks stale is usually a stale profile, not a stale build.
- **Screens** (the other cards), **Foundations**, **Components** are
  screenshots of the same widgets, shot headless at a fixed viewport per card,
  light and dark.
- `app/` is a Flutter web build. 39 files of engine, and not readable as
  source. Do not edit anything under it.

## What the app will not do here

- **There are no routes.** Navigation is a drawer plus pushed screens, so no
  URL opens a particular screen. One live card, not one per screen.
- **No WebView.** The app renders sites through a native webview that does not
  exist on web. Where site content would be, the app shows a placeholder. The
  design here is the chrome around the content.
- **Flutter paints into a canvas.** There is no DOM to inspect or restyle: no
  CSS in this project reaches the app, and devtools shows one `<canvas>`.

## Changing the design

The values a design change usually needs live in two Dart files in the app
repository, not here:

- `lib/theme/design_tokens.dart` for radii, spacing, fixed chrome colours,
  motion durations, icon sizes, tap targets.
- `lib/theme/accent_theme.dart` for the eight accents and every colour role
  derived from them.

Editing the HTML of a card in this project changes nothing about the app, and
the page is overwritten on the next publish. The cards are output.

## Asking for a rebuild

This project has no shell, no Node, and no Flutter, so it cannot rebuild
`app/` or re-shoot a card. `_requests/refresh.md` is how to ask. Overwrite it
with a unique `id:` line and a plain-English description of what to refresh; a
session with the toolchain compares that id against `_requests/status.md`,
rebuilds, re-uploads, and writes back what it did. Full protocol is in the
file itself.

## What holds the app to the design

The app repository runs the checks, not this project: every card must clear an
ink floor (a blank card means the engine or the font failed to load), every
accent must hold 4.5:1 contrast across both brightnesses, every design value in
a migrated widget must come from the token file rather than a literal, and the
packed `app/` must boot in an iframe. A design change that breaks one of those
fails there, before it reaches here.
