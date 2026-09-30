# BUG-022 - A partial settings object resets every field it leaves out (Android)

Status: **open.** Found by reading source on 2026-09-30, during the
accessibility audit; not yet reproduced on a device.

**Spec:** [accessibility](../../openspec/specs/accessibility/spec.md) A11Y-007;
[webview-pause-lifecycle](../../openspec/specs/webview-pause-lifecycle/spec.md)
PAUSE-032 (attempt 2)
**Tests:** [test/js/composition_mode_parity.test.js](../../test/js/composition_mode_parity.test.js)
(one field, attempt 2). Nothing yet covers the class.

## Symptom

A per-site setting that was right when the webview was created changes
later, when the app calls `setSettings` for an unrelated reason. Nothing
fails and nothing is logged. The instances open today:

- **The system font size changes** (`didChangeTextScaleFactor` runs
  `setTextZoom` for every loaded site): a JavaScript-off site gets
  JavaScript, the webview accepts third-party cookies, an incognito site's
  webview leaves incognito, a desktop-mode site drops desktop mode, and
  media stops autoplaying. The user changed an accessibility setting.
- **Every controller attach** (`WebViewModel.setController` runs
  `setOptions`): a desktop-mode site drops desktop mode, so it loses pinch
  zoom (`setSupportZoom(false)`, `setBuiltInZoomControls(false)`) and its
  wide viewport; a page-zoomed site gets `loadWithOverviewMode` back on
  against `WebViewFactory`'s stated need for it off; every site's media goes
  back to needing a gesture.

## Root mechanism / invariant

The fork's Dart `setSettings` sends `settings.toMap()`, which carries every
field of `InAppWebViewSettings`, and the constructor gives most fields a
non-null default: `javaScriptEnabled` true, `thirdPartyCookiesEnabled` true,
`incognito` false, `preferredContentMode` RECOMMENDED,
`mediaPlaybackRequiresUserGesture` true, `loadWithOverviewMode` true,
`useHybridComposition` true. Android's native `InAppWebView.setSettings`
applies each key that is present and differs from the webview's current
value (`preferredContentMode` through `setDesktopMode`, `incognito` through
`setIncognito`). So a settings object built to change one field is an
instruction to reset every other field to the plugin default.

The invariant: **every settings object passed to `setSettings` names every
field the site configured, with the site's value**, or starts from the
webview's own current settings (`getSettings()`) and changes only the field
it means to. Building a fresh `InAppWebViewSettings` with a few fields set is
never a partial update on Android.

Each attempt below fixed one field, on one path or on every path, and left
the rest.

## Fix attempts

1. **2026-04-26 - #246** (`df2b655c`, "Respect system text scale in webview
   content"). `setOptions` began carrying
   `textZoom: WebViewFactory.systemTextZoomPercent()`, with the comment that
   the constructor defaults it to 100 and `toMap` always emits it. *Why*: an
   options update reset the user's font scale. *Why partial*: it fixed one
   field on one call site, and the same change added `setTextZoom`, which
   builds `InAppWebViewSettings(textZoom: ...)` on its own, the shape it had
   just fixed. That is the font-size instance above.

2. **2026-09-27 - #635** (`a484270`, PAUSE-032). Every settings object the
   app builds carries `useHybridComposition`, held by
   `test/js/composition_mode_parity.test.js`. *Why*: an omitted field told a
   texture-mode webview it was in hybrid composition. *Why partial*: the gate
   holds one field across every call site; `javaScriptEnabled`,
   `thirdPartyCookiesEnabled`, `incognito`, `preferredContentMode`,
   `mediaPlaybackRequiresUserGesture` and `loadWithOverviewMode` are still
   unguarded, which is how the two open instances pass it.

## Known open gaps

1. `WebViewController.setTextZoom` (Android branch) resets JavaScript,
   third-party cookies, incognito, desktop mode and the media gesture rule.
   Fires on every OS font size change, for every loaded site and every open
   nested browser.
2. `WebViewController.setOptions` resets desktop mode (and with it pinch
   zoom), `loadWithOverviewMode` and the media gesture rule on every
   controller attach.
3. No gate covers the class. A structural gate in the shape of
   `composition_mode_parity` could require every `setSettings` argument to
   come from one builder shared with creation, or from `getSettings()`.
   The effect side belongs in `integration_test/settings_seam_test.dart`,
   which today compares fields only at creation: re-read them after a
   `setTextZoom` and after `setOptions`.
4. iOS and macOS were not examined for the same shape. Their `setSettings`
   is a different native implementation.
