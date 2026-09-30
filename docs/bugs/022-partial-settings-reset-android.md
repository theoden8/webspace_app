# BUG-022 - A partial settings object resets every field it leaves out (Android)

Status: **closed.** Attempt 3 subsumes the per-field fixes: every update
sends the settings the webview was created with, and
`settings_update_whole.test.js` fails any `setSettings` call that sends
anything else. Found by reading source on 2026-09-30, during the
accessibility audit.

**Spec:** [accessibility](../../openspec/specs/accessibility/spec.md) A11Y-007;
[webview-pause-lifecycle](../../openspec/specs/webview-pause-lifecycle/spec.md)
PAUSE-032 (attempt 2)
**Tests:** [test/js/settings_update_whole.test.js](../../test/js/settings_update_whole.test.js)
(every `setSettings` call sends the creation settings),
[test/webview_settings_update_test.dart](../../test/webview_settings_update_test.dart)
(the native diff modelled: a fresh object against an update of the creation
settings), [integration_test/settings_seam_test.dart](../../integration_test/settings_seam_test.dart)
"an update after creation keeps every field it does not own" (the effect, on
the Android, Linux and Apple tiers);
[test/js/composition_mode_parity.test.js](../../test/js/composition_mode_parity.test.js)
(one field, attempt 2).

## Symptom

A per-site setting that was right when the webview was created changes
later, when the app calls `setSettings` for an unrelated reason. Nothing
fails and nothing is logged. The instances attempt 3 closed:

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

3. **2026-09-30 - #656** (`4b9aa7d`). `_WebViewController` keeps the
   `InAppWebViewSettings` its webview was created with. `setOptions` writes
   the fields it owns onto that object (`applyWebViewOptions`) and
   `setTextZoom` writes `textZoom`; both send the whole object. Every field
   the update does not own goes out with the value the engine already holds,
   so Android and iOS/macOS find nothing else to apply and Linux re-applies
   the site's own settings. *Why*: the invariant has to hold for fields
   nobody has named yet, which a per-field list (attempts 1 and 2) cannot
   do. *Also found while fixing*: iOS and macOS diff the same way as Android,
   and Linux's `setSettings` replaces the whole settings object, so before
   this every `setOptions` on Linux reset every per-site field the call did
   not name. The object is shared with the widget's `initialSettings`, so a
   remount of the same widget (the renderer-gone key bump) starts from the
   latest values rather than the creation ones. *Confirmed* by the seam
   scenario in CI run 36785447487: after `setOptions` and `setTextZoom` the
   Android emulator held all seven fields it compares (JavaScript, incognito,
   third-party cookies, desktop content mode, `supportZoom`, the media
   gesture rule, `textZoom`), macOS held JavaScript, incognito and content
   mode, and Linux held JavaScript, the one field its readback reports.

## Known open gaps

1. Popup webviews (`onCreateWindow`) have no controller wrapper and never
   receive a settings update, so they are outside the class today; a future
   update path for them has to go through the same rule.
