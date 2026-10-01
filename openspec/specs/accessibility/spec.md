# Accessibility Specification

## Purpose

Which OS accessibility features WebSpace supports, on which platform, and
what App Store Connect's Accessibility Nutrition Labels may claim for it.

The app has two surfaces with different owners:

- **The chrome** (drawer, tab strip, URL bar, settings screens, dialogs) is
  the app's own Flutter UI. Its accessibility is entirely ours.
- **Web content** belongs to the site. The engine (WKWebView, Android
  WebView, WPE WebKit) already implements accessibility for it: a screen
  reader tree built from the page's ARIA and alt text, the accessibility
  media queries, caption rendering from the page's `<track>` elements. The
  app's job is to put that engine in front of the user without getting in
  its way, and to supply the few inputs the engine takes from its embedder
  rather than from the OS (text size, colour scheme).

Apple's labels are all or nothing per device: "users must be able to
complete all of the common tasks of your app using that feature". There is
no partial claim. Third-party content is exempt from the per-feature
criteria, but the app "should provide the third-party content creators a
reasonable, discoverable way to make their content accessible". For a
browser that way is the web platform itself, so the exemption holds only
while the app passes the platform through (A11Y-003).

Google Play asks for no declaration at all. Its bar is a short list of
criteria and an automated report on every test-track upload, set out under
"Android's criteria" below.

Sources: Apple's
[overview](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/overview-of-accessibility-nutrition-labels)
and its nine per-feature evaluation criteria pages, linked from it; Google's
[core app quality guidelines](https://developer.android.com/docs/quality-guidelines/core-app-quality)
and [accessibility testing guide](https://developer.android.com/guide/topics/ui/accessibility/testing).

## Status

- **Status**: In Progress. Audit of master `5e1788f` on 2026-09-30; every
  label is currently answered No (A11Y-001). Line numbers below are at that
  commit.
- **Platforms**: all. The declaration covers iPhone, iPad and Mac; Android
  is held to A11Y-014 to A11Y-016 and the criteria they cite.

---

## Common tasks

What Apple's "common tasks" means for this app. A label is claimed only when
every one of these works with the feature on.

1. First launch: the empty state, the suggested sites, adding a first site.
2. Add, edit and delete a site.
3. Switch sites: drawer, tab strip, tabs sheet.
4. Use a site: read and operate the page, back, reload, URL bar, find in page.
5. Webspaces: create, select, change membership.
6. Settings: a site's screen and its Behaviour, Network, Privacy and
   Permissions screens; App settings.
7. Settings export and import.
8. Unlock an archive (passphrase).

The app has no login and no purchase of its own. Developer tools are not a
common task.

## The categories on each platform

Apple's nine labels, the setting behind each on every platform, and what
Flutter 3.38.6 (`.fvmrc`) hands to Dart for it. Read from the engine source
at tag `3.38.6`: iOS `FlutterViewController.mm` (`onAccessibilityStatusChanged`),
Android `AccessibilityBridge.java`, Linux `fl_settings_handler.cc`, macOS
`FlutterEngine.mm`.

| Label | iOS / iPadOS | macOS | Android | Linux (GNOME) | Flutter signal | Web signal |
|---|---|---|---|---|---|---|
| VoiceOver | VoiceOver | VoiceOver | TalkBack | Orca (AT-SPI) | semantics tree | engine's tree (ARIA, alt) |
| Voice Control | Voice Control | Voice Control | Voice Access | none built in | semantics labels | engine's tree |
| Larger Text | Dynamic Type | no system setting | Font size | `text-scaling-factor` | `textScaler` on iOS, Android, Linux; always 1.0 on macOS | none standard |
| Dark Interface | Dark appearance | Dark appearance | Dark theme | `color-scheme` | `platformBrightness` | `prefers-color-scheme` |
| Differentiate Without Color Alone | Differentiate Without Color | same | none | none | not delivered | none |
| Sufficient Contrast | Increase Contrast | Increase Contrast | High contrast text | `high-contrast` | `highContrast` on iOS and Linux only | `prefers-contrast` |
| Reduced Motion | Reduce Motion | Reduce Motion | Remove animations | `enable-animations` off | `accessibilityFeatures.reduceMotion` on iOS; `MediaQuery.disableAnimations` on Android and Linux; nothing on macOS | `prefers-reduced-motion` |
| Captions | Subtitles & Captioning | same | Caption preferences | none | n/a | `<track kind="captions">` |
| Audio Descriptions | Audio Descriptions | same | Audio description | none | n/a | engine track selection |

Three facts from that source that code must not assume away:

- **iOS Reduce Motion never reaches `MediaQuery.disableAnimations`.** iOS sets
  only the `reduceMotion` flag, and `MediaQueryData.fromView` reads
  `disableAnimations` alone. Code that checks only `MediaQuery` ignores
  Reduce Motion on iPhone.
- **The macOS embedder sends no accessibility flags** and hard-codes
  `textScaleFactor: 1.0`. On the Mac, Flutter cannot see Reduce Motion,
  Increase Contrast or a text size.
- **`highContrast` is iOS Increase Contrast (darker system colours) and
  GNOME High Contrast.** Android's high contrast text is not delivered.

Also delivered, with no Apple label: `boldText` (iOS, Android),
`invertColors` (iOS), `onOffSwitchLabels` (iOS).

## What the engines give web content

"Source" means read from the engine or plugin source; "device" means it
needs a check on hardware before anything relies on it.

| | iOS WKWebView | macOS WKWebView | Android WebView | Linux WPE (fork) |
|---|---|---|---|---|
| Screen reader reaches the page | expected: the engine wraps a `UiKitView` in `FlutterPlatformViewSemanticsContainer` (source; device) | **no** (source; device): `FlutterViewWrapper` hands AppKit only the Flutter view, the Flutter view's `accessibilityChildren` is the semantics root, and `FlutterPlatformNodeDelegateMac` has no platform-view case | expected: `AccessibilityBridge` embeds the platform view's nodes (source; device) | **no**: the page is a Flutter `Texture` (`custom_platform_view.dart`), and the fork has no ATK or AT-SPI code |
| System text size | only through `font: -apple-system-body`; the app injects `-webkit-text-size-adjust` (A11Y-007) | nothing to follow (1.0) | follows `fontScale` until the embedder calls `setTextZoom` (`AwSettings.updateFontScaleLocked`); the plugin always calls it, so the app sets `textZoom` itself (A11Y-007) | nothing reads `text-scaling-factor`; the app's CSS is probably ignored (device) |
| `prefers-color-scheme` in CSS | the view's appearance, which follows the system, not the app theme | same | the activity theme (`values-night`), so the system (device) | `WPE_SETTING_DARK_MODE`, which the app never sets |
| `prefers-reduced-motion` | Reduce Motion (device) | same (device) | Remove animations: `ANIMATOR_DURATION_SCALE == 0` (`AccessibilityState.prefersReducedMotion`, fed to `WebPreferences` by `web_contents_impl.cc`) | only through the fork's `disableAnimations`, which the app never sets; upstream WPE 2.54 inverts the value ([WebKit#74861](https://github.com/WebKit/WebKit/pull/74861), open) |
| `prefers-contrast` | Increase Contrast (WebKit since Safari 14.1; device) | same | not established | not established |
| Invert colours | Smart Invert applies (`accessibilityIgnoresInvertColors` is false) | n/a | n/a | n/a |
| Captions | engine media controls (device) | same | `CaptioningController` applies the system caption style to text tracks (source) | none known |
| Pinch zoom | a site's `user-scalable=no` is honoured (`ignoresViewportScaleLimits` false) | n/a | on; desktop-mode sites lost it on every controller attach until BUG-022's fix | the controller's zoom level only |

The app's own layers on top of that are A11Y-003 (what it must not change)
and A11Y-007 and A11Y-008 (what it supplies).

## Android's criteria

Google Play has no counterpart to Apple's labels. A developer declares
nothing; the only accessibility marks on a listing are tags Google assigns
itself, which it had given to a handful of apps when they appeared
([2022](https://www.xda-developers.com/google-play-store-a11y-tags-accessibility-apps/)).
Play's accessibility policy governs apps that implement an
`AccessibilityService`, and this app has none. What Google does set is:

- **Core app quality**, three criteria: `Touch_Target_Size` (at least
  48 dp), `Visual_Contrast` (4.5:1 for text under 18 pt, or under 14 pt
  bold; 3:1 for larger text and for graphics) and `Content_Description`
  (every element except plain text is described).
- **The Play pre-launch report**, run on every upload to a test track. Its
  accessibility warnings fall under content labelling, touch target size,
  implementation (traversal order, element attributes) and low contrast.
  Accessibility Scanner runs checks of the same kind on a device, from the
  Accessibility Test Framework.
- **Manual tests.** TalkBack: every element reachable by swiping, alerts read
  aloud, the main workflows complete. Switch Access: an item is highlighted
  only if it is actionable and only once, and every gesture is also a
  selectable control. Voice Access.

The criteria map onto A11Y-005, A11Y-010 and A11Y-014, the manual tests onto
A11Y-004, A11Y-005 and A11Y-015, and A11Y-016 puts the report into the
release. Against those, the Android build fails today on labels (A11Y-005),
contrast (A11Y-010) and touch targets (A11Y-014).

Each Android setting and where it stands, from Flutter 3.38.6's
`AccessibilityBridge.java` and Chromium's `AwSettings.java`:

| Setting | Chrome (Flutter) | Web content (WebView) | Requirement |
|---|---|---|---|
| TalkBack | semantics tree; `accessibleNavigation` once a service reads the node tree | the WebView's own node tree through the platform view (device) | A11Y-004, A11Y-005 |
| Switch Access | a node is clickable only if its semantics has a tap action, so Switch Access cannot tap the drawer's site tile or the tab chip | WebView nodes (device) | A11Y-005 |
| Voice Access | semantics labels | [flutter#40913](https://github.com/flutter/flutter/issues/40913), open since 2019: embedded platform views lack Voice Access support (device) | A11Y-004, A11Y-005 |
| Font size, up to 200% on Android 14 | `SystemTextScaler` applies the platform's nonlinear curve | `textZoom = fontScale * 100`, the linear value WebView itself defaults to | A11Y-006, A11Y-007 |
| Bold text | `boldText`; `Text` merges `FontWeight.bold` on its own | no path found in `AwSettings` or `web_contents_impl.cc` | none |
| High contrast text | not delivered | not established | A11Y-010 |
| Dark theme | `platformBrightness` | the activity theme | A11Y-008 |
| Colour correction, colour inversion | system filters over the whole screen | same | A11Y-009 |
| Remove animations | `disableAnimations` | `prefers-reduced-motion` | A11Y-011 |
| Caption preferences | n/a | `CaptioningController` styles text tracks | A11Y-002 |
| Time to take action | not delivered: the bridge never reads `getRecommendedTimeoutMillis` | n/a | A11Y-015 |
| Magnification | system | system | none |

---

## Requirements

### Requirement: A11Y-001 - The declaration follows the audit

The Accessibility Nutrition Labels in App Store Connect SHALL match the table
below. A label SHALL be answered Yes for a device only when the requirement
named in its row holds on that device for every common task, and a person
has checked it there with the OS feature on. The iPhone/iPad answer and the
Mac answer are separate and may differ. The table SHALL be revisited on every
release that changes the chrome, since Apple asks for a re-evaluation per
update.

| Label | iPhone, iPad | Mac | Holds when |
|---|---|---|---|
| VoiceOver | No | No | A11Y-004, A11Y-005, A11Y-012 |
| Voice Control | No | No | A11Y-004, A11Y-005 |
| Larger Text | No | No | A11Y-006, A11Y-007 |
| Dark Interface | No | No | A11Y-008 (one device check away) |
| Differentiate Without Color Alone | No | No | A11Y-009 |
| Sufficient Contrast | No | No | A11Y-010 |
| Reduced Motion | No | No | A11Y-011 |
| Captions | No | No | not applicable (A11Y-002) |
| Audio Descriptions | No | No | not applicable (A11Y-002) |

Why each is No today, in one line each:

- **VoiceOver, Voice Control**: 13 icon buttons and both FABs are unlabelled,
  the add-site FAB included (first launch); the drawer's site tile has no
  tap action; several actions exist only as long press, drag or swipe. On
  the Mac the page itself is unreachable (A11Y-004).
- **Larger Text**: nothing clamps the scale, but the drawer tile, tab strip
  and tab counter are fixed-size boxes that no test renders at 200%. On the
  Mac Flutter reports 1.0 and there is no in-app text size.
- **Dark Interface**: the chrome is ready; whether a webview paints white
  before its first frame in dark mode is unchecked.
- **Differentiate Without Color Alone**: the selected site in the drawer is a
  tint only.
- **Sufficient Contrast**: accent-coloured section headers and several
  hard-coded greys and oranges fall below 4.5:1 on the light theme.
- **Reduced Motion**: nothing reads the OS setting.

#### Scenario: A label is claimed

**Given** a release is being submitted
**When** a label is answered Yes for a device
**Then** the requirement in its row holds on that device
**And** it was checked on that device with the OS feature on

#### Scenario: A chrome change lands after a label was claimed

**Given** Voice Control is answered Yes for iPhone
**When** a release adds an icon-only button without a label
**Then** A11Y-005's gate fails before the release, or the answer goes back to No

---

### Requirement: A11Y-002 - Captions and audio descriptions are not declared

The app SHALL answer No to Captions and Audio Descriptions on every device.
It plays no dialogue, narration or audio-only content of its own: the only
video it renders is the user's own muted clip in the virtual camera and
screen-share preview (`lib/widgets/virtual_source_preview.dart`), and the
virtual microphone shows only a file name. Apple's third-party route needs
the app to show which content is captioned or described, which a browser
cannot know. Captions in web media are the engine's, rendered from the
site's tracks; A11Y-003 keeps the app out of their way.

#### Scenario: A web video with captions

**Given** a site plays a `<video>` with a `<track kind="captions">`
**When** the user turns captions on in the engine's media controls
**Then** the engine renders them, styled by the OS caption settings where
the engine supports that
**And** no app shim touches `TextTrack` or the `<track>` element

---

### Requirement: A11Y-003 - The engine's own accessibility passes through

The app SHALL NOT change what the engine reports for `prefers-reduced-motion`,
`prefers-contrast`, `forced-colors`, `inverted-colors` or
`prefers-reduced-transparency`, in CSS or in `matchMedia`, on any site,
including under Tracking Protection. These are fingerprinting bits, and
this requirement is the decision to leave them alone under Tracking
Protection: flattening them hides the user's need from every site, which
costs more than the entropy they carry.

The app SHALL NOT inject `user-scalable=no`, `maximum-scale` or
`minimum-scale`, SHALL NOT hide elements by `role` or `aria-*`, and SHALL
NOT set `accessibilityIgnoresInvertColors`.

Status, at `5e1788f`:

- **Holds** for every shim except one. No shim handles any of the five
  features; the anti-fingerprinting `matchMedia` wrapper touches only
  `device-width`, `device-height` and `device-aspect-ratio`.
- **Breaks for compound colour-scheme queries.** The theme shim
  (`lib/services/theme_color_scheme_shim.dart:49`) answers any query whose
  text contains `prefers-color-scheme` from the app theme alone, so
  `(prefers-color-scheme: dark) and (prefers-contrast: more)` loses its
  contrast half. It should answer the colour-scheme feature and evaluate
  the rest of the query against the original `matchMedia`.
- **Known costs, kept on purpose** (Tracking Protection):
  `speechSynthesis.getVoices()` returns `[]` (ETP-011), so a page's
  read-aloud control finds no voice list, although `speak()` still uses the
  engine's default voice; `navigator.maxTouchPoints` is 0 under a mobile UA
  (`anti_fingerprinting_shim.dart:430-439`), so a site that sizes touch
  targets from it gets its desktop layout.
- The page-zoom and desktop-mode viewport rewrites replace a site's viewport
  `content` wholesale, which drops its `user-scalable=no`. That widens what
  the user can do and is allowed.

Gate to add: a browser-tier test (`test/browser/`) that installs the full
DOCUMENT_START payload, emulates each feature with Puppeteer's
`emulateMediaFeatures`, and asserts that `matchMedia` and a CSS `@media`
probe both report the emulated value, alone and combined with
`prefers-color-scheme`.

#### Scenario: Reduce Motion on a tracking-protected site

**Given** the OS asks for reduced motion
**And** a site has Tracking Protection on
**When** the page evaluates `matchMedia('(prefers-reduced-motion: reduce)')`
**Then** it matches, exactly as it would without any app shim

#### Scenario: Compound query

**Given** the app theme is dark and the OS asks for more contrast
**When** the page evaluates
`matchMedia('(prefers-color-scheme: dark) and (prefers-contrast: more)')`
**Then** it matches

---

### Requirement: A11Y-004 - A screen reader reaches the site on screen

For the site on screen, the platform screen reader SHALL reach the page's
own accessibility tree, and SHALL NOT reach the chrome or pages of sites
that are not on screen. On Android this SHALL hold in both composition
modes (hybrid, and the texture experiment of PAUSE-032).

The chrome side holds by construction: `WebspacesListScreen` and the site
stack sit in `Offstage`s that exclude each other, and `IndexedStack` wraps
each hidden child in `Visibility` with `maintainSemantics` false (Flutter
3.38.6 `basic.dart`). The inner `Visibility` around the stack also drops
semantics, so on Android the site's subtree leaves the tree for the 120 ms
of `_holdUnpainted` (the BUG-001 repaint nudge), when the WebView also
leaves the native hierarchy. Whether TalkBack keeps its place in the page
across that needs a device check.

The page side is the engine's:

- **iOS, Android**: expected to hold; needs a device check with VoiceOver and
  TalkBack.
- **macOS**: does not hold. Flutter's macOS accessibility bridge exposes only
  the semantics tree, never an `AppKitView`. Nothing in the app or the fork
  can fix it; it needs Flutter to expose platform views on macOS, and until
  then VoiceOver and Voice Control stay No on the Mac.
- **Linux**: does not hold. The page is a texture. Reaching it needs the fork
  to parent WPE's AT-SPI tree under Flutter's ATK node for the view.

#### Scenario: VoiceOver on a site (iOS)

**Given** VoiceOver is on and a site is on screen
**When** the user swipes right from the app bar
**Then** focus moves into the page's headings, links and controls in reading
order
**And** no element of another loaded site is reachable

#### Scenario: TalkBack in texture mode (Android)

**Given** texture page rendering is on (PAUSE-032) and TalkBack is on
**When** the user explores the page by touch
**Then** TalkBack announces the element under the finger

---

### Requirement: A11Y-005 - Every control has a name, a role and an action

Every interactive element of the chrome SHALL:

- have an accessible name, from `tooltip:` or a `Semantics` label, and where
  it shows text the name SHALL contain that text (Voice Control users speak
  what they see);
- expose its action through semantics (`onTap` or a button that has one),
  never only through raw pointer events;
- carry selected, checked, toggled or expanded as semantics state, not as
  words in the label;
- offer every action that is otherwise only a long press, drag, swipe,
  double tap or secondary click through a labelled control or a
  `CustomSemanticsAction`.

Status changing without focus (the find counter, Tor bootstrap progress)
SHALL be announced, through `liveRegion` or `SemanticsService.announce`.

Known failures at `5e1788f`:

| Where | What |
|---|---|
| `main.dart:10703`, `user_scripts.dart:517` | FABs (add site, add script) with no tooltip |
| `main.dart:4978`, `8413`; `inappbrowser.dart:1069`; `dev_tools.dart:380`; `link_handling_settings.dart:447`, `536`; `webspaces_list.dart:117`, `133`; `find_toolbar.dart:65`, `73`, `81` | icon buttons with no tooltip |
| `http_auth_prompt.dart:101`, `proxy_auth_section.dart:111` | show/hide password: no name, no toggled state |
| `tab_bar_corner_button.dart:47` | floating tabs button: no name |
| `main.dart:9879` | drawer site tile opens on a raw `Listener`; its `Semantics(button: true)` has no `onTap`, so activation depends on the OS synthesising a touch |
| `main.dart:8503` | tab chip: the same, and no `selected` |
| `main.dart:9920` | site menu button: unlabelled, about 24x24, the only non-long-press route to the site menu |
| `main.dart:10431` | fullscreen exit handle: unlabelled |
| `stats_banner.dart:80` | expand/collapse with no button role or expanded state |
| `main.dart:7851` | theme toggle tooltip names Green for every accent but Blue |
| `main.dart:8128-8200` | back, home, share and refresh inside one `PopupMenuItem`, whose `MergeSemantics` makes them one node |
| drawer grid, tab strip | reorder by drag only (the drawer's Move up/down sits behind the site menu); no custom action on the tab strip |
| `user_scripts.dart:379-442` | in the global library, swipe is the only way to delete a script |
| `add_site.dart:880`; `main.dart:8177` | remove a suggestion, duplicate a tab: long press only |
| `tor_bridge_settings.dart:209` | bridge CAPTCHA image: no label and no alternative challenge |
| `find_toolbar.dart:64`, `tor_bootstrap.dart` | match counter and progress change silently |

A `HintButton` inside a `SwitchListTile` title (about 17 call sites) is
merged into the tile's node by the tile's own `MergeSemantics`, so the hint
has no node of its own there; whether a reader can still open it needs a
device check.

Gates to add: a structural test under `test/js/` that fails an `IconButton`
or `FloatingActionButton` with neither `tooltip:` nor an enclosing
`Semantics(label:)`, and a `Listener` or `GestureDetector` with a tap
handler and no `Semantics(onTap:)`; widget tests of the drawer, tab strip,
app bar and settings screens against `labeledTapTargetGuideline`,
`androidTapTargetGuideline` and `iOSTapTargetGuideline`.

#### Scenario: Voice Control opens a site

**Given** Voice Control is on and the drawer is open
**When** the user says "Tap" and a site's name
**Then** that site opens

#### Scenario: Screen reader reorders a site

**Given** a screen reader is on and a webspace with three sites is selected
**When** the user focuses the second site in the drawer
**Then** Move up and Move down are offered as actions on it
**And** choosing one reorders the site without a drag

---

### Requirement: A11Y-006 - The chrome scales with the system text size

The chrome SHALL NOT clamp the text scale. Every common-task screen SHALL lay
out at `TextScaler.linear(2.0)`, and at 3.1 (the body size of iOS AX5),
without overflow and without losing a control. Text that is truncated SHALL
be available in full elsewhere (a tooltip, the site info sheet, the detail
screen).

On the Mac, Flutter reports 1.0 whatever the OS says. Apple accepts an
in-app text size control in place of the system one, and per-site page zoom
already covers web content that way, but the chrome has none. Larger Text on
the Mac needs an app-wide UI scale setting.

Status: nothing clamps. Fixed boxes that will clip: the drawer grid cell
(`mainAxisExtent: 88`, `main.dart:10653`), the tab strip (`height: 52`,
`main.dart:8397`), the tab counter (22x22, `main.dart:7881`), the download
badge (28x28). `test/design_render_matrix_test.dart` renders six widgets at
2.0; none of the drawer, tab strip, app bar or settings screens.

Gate to add: extend the render matrix to the drawer tile, tab strip, app bar,
Add site and the settings screens, at 2.0 and 3.1, in English and in one
locale with long words.

#### Scenario: Largest accessibility size (iOS)

**Given** iOS Dynamic Type is at AX5
**When** the user opens the drawer
**Then** every site name is readable, wrapping or truncated with the full
name reachable
**And** no tile overlaps another

---

### Requirement: A11Y-007 - The system text size reaches web content

Web content SHALL render at the OS text size, scaled on top of the site's
per-site page zoom (ZOOM-001), and SHALL follow a change of the OS setting
without a reload. Changing the OS text size SHALL NOT change any other
setting of any site.

- **Android**: `textZoom = round(textScaleFactor * 100)` at creation
  (`WebViewFactory.systemTextZoomPercent`), repeated in every `setSettings`
  call so the plugin's default does not reset it, and applied to every loaded
  site and open nested browser by `didChangeTextScaleFactor`.
- **iOS**: a DOCUMENT_START script for all frames sets
  `html{-webkit-text-size-adjust:N%}`, rotated on change. A site that sets
  the property on `body` or deeper wins by inheritance.
- **macOS**: there is no OS value to follow (A11Y-006).
- **Linux**: the same CSS path runs (the gate is `!hostIsAndroid`), but
  desktop WebKit is not known to honour a percentage
  `-webkit-text-size-adjust`, and nothing maps GNOME's `text-scaling-factor`
  to a WPE setting. Treat Linux as unsupported until a device check says
  otherwise.

Status: until `4b9aa7d` the Android change path was unsafe. `setTextZoom`
sent a fresh `InAppWebViewSettings(textZoom:)`, whose other fields carry the
plugin's defaults, and the engine applied every one that differed: a font
size change turned JavaScript back on for a JavaScript-off site, accepted
third-party cookies, took a site out of incognito and dropped desktop mode
([BUG-022](../../../docs/bugs/022-partial-settings-reset-android.md)). Every
update now sends the settings the webview was created with, changed only in
the fields it owns; `settings_seam_test.dart` checks the effect on the
Android, macOS and Linux tiers. Popups (`WebViewFactory` popup path) still miss live updates.

#### Scenario: Font size changes while a JavaScript-off site is loaded (Android)

**Given** a loaded site with JavaScript off and third-party cookies off
**When** the user raises the system font size and returns to the app
**Then** the page text grows
**And** JavaScript and third-party cookies stay off for that site

#### Scenario: Font size and page zoom together

**Given** a site at 150% page zoom and a system font scale of 1.3
**When** the page loads
**Then** its layout is zoomed 150% and its text is scaled by a further 1.3

---

### Requirement: A11Y-008 - The interface stays dark

With the app in dark mode (by the system under `ThemeMode.system`, the
default, or by the in-app toggle), every screen, dialog, sheet and menu of
the chrome SHALL be dark, and no webview SHALL paint a white frame before
the page's own first paint. Pages SHALL receive the app's scheme through the
theme shim (HINTS-001, HINTS-002). A page with no dark style of its own
stays light; that is third-party content and outside the claim.

Status: the chrome holds. `highContrastTheme` and `highContrastDarkTheme`
are not set (A11Y-010). Two gaps:

- **Unchecked flash.** Whether a webview shows its default white background
  in the frames before a dark page paints, on creation and on site switch,
  has not been looked at on a device. This is the one check between Dark
  Interface and Yes.
- **CSS and JS can disagree.** The shim overrides `matchMedia` and the root
  `color-scheme`, but a stylesheet's `@media (prefers-color-scheme)` follows
  the engine, which follows the system, not the app. With the app dark and
  the system light, JS reports dark and CSS reports light. The engine-level
  fix is per platform: the webview's `overrideUserInterfaceStyle` (iOS) or
  `appearance` (macOS) in the fork, the fork's existing `darkMode` setting
  on Linux, and the activity's night mode on Android. Under
  `ThemeMode.system`, `didChangePlatformBrightness` is not handled, so the
  JS answer is stale until the next load.

#### Scenario: Opening a dark site in dark mode

**Given** the app is dark and a site's page has a dark background
**When** the user opens the site for the first time this session
**Then** no white frame is visible between the drawer closing and the page
painting

---

### Requirement: A11Y-009 - Nothing is told by colour alone

Every state or value the common tasks distinguish SHALL carry a cue other
than hue: an icon, a shape, text, weight or a border. The check is the OS
Grayscale filter.

Holds: proxy status (text beside the dot), proxy test (icon and text),
permission badges (filled or outlined glyph, and a spoken label), the "Not
configured" warning (icon and text), the active tab chip (border and
weight), the selected webspace (elevation and weight), the theme and accent
pickers.

Fails:

- the selected site tile in the drawer, a `primaryContainer` tint only
  (`main.dart:9968`);
- the DNS statistics chips on a site's Privacy screen, where two chips share
  one label and differ by red against orange (`site_privacy.dart:603-609`);
- the block statistics daily bars, one colour with no labels and no
  semantics (`block_stats.dart:36-66`), which also fails VoiceOver's rule for
  charts;
- dev tools log severity (not a common task, same fix).

#### Scenario: Which site is open (Grayscale)

**Given** the Grayscale colour filter is on and the drawer is open
**When** the user looks for the site on screen
**Then** its tile is marked by something other than colour
**And** the screen reader reports it as selected

---

### Requirement: A11Y-010 - Text and state meet contrast minimums

In both brightnesses and for every accent: text SHALL be at least 4.5:1
against its background (3:1 for text of 24 px, or 18.66 px bold), and a
non-text indicator of state (a switch track, a checkbox, a selection
border) SHALL be at least 3:1. When `MediaQuery.highContrast` is true (iOS
Increase Contrast, GNOME High Contrast), the app SHALL use
`highContrastTheme` / `highContrastDarkTheme`.

`test/accent_theme_contrast_test.dart` holds seven role pairs to 4.5:1 for
every accent. It does not cover `primary` used as text on `surface`, which is
how the settings screens draw section headers (`settings.dart:834`,
`site_behaviour.dart:118`, and six more). Ratios on the light theme:

| Where | Colour | On white |
|---|---|---|
| section headers | accent `primary`, all eight | 1.56 (green) to 3.40 (red); blue, the default, 3.28 |
| drawer domain, list captions | `Colors.grey` | 2.68 |
| "Not configured" subtitle | `Colors.orange` | 2.16 |
| destructive labels | `Colors.red` | 3.68 |
| statistics banner | grey 500 on grey 100 | 2.46 |

On black every accent clears 6:1.

Gates to add: a `primary`-on-`surface` pair in the accent contrast test (or
headers drawn in a role that passes), and a structural test that fails
`Colors.grey`, `Colors.orange`, `Colors.amber` or `Colors.red` as a text
colour in the chrome.

#### Scenario: Light theme, yellow accent

**Given** the light theme with the yellow accent
**When** the user opens a site's settings
**Then** the section headers are at least 4.5:1 against the background

---

### Requirement: A11Y-011 - Motion stops when the OS asks

The app SHALL treat motion as reduced when
`MediaQuery.disableAnimationsOf(context)` is true (Android, Linux) or
`platformDispatcher.accessibilityFeatures.reduceMotion` is true (iOS). One
helper SHALL answer this, and no widget SHALL read either flag directly.
Under reduced motion:

- decorative motion SHALL stop or become a cross-fade: the spinning sync
  icon of the blocklist and timezone downloads in App settings
  (`_spinController`, `app_settings.dart:312`), the corner button's glide
  (`main.dart:10468`), `AnimatedScale` on press, `AnimatedSize` in the
  statistics banner;
- the virtual camera and screen-share preview SHALL NOT autoplay; it shows
  its first frame and plays on request;
- platform progress indicators MAY keep their platform behaviour.

On the Mac, Flutter delivers neither flag; the helper SHALL read
`NSWorkspace.shared.accessibilityDisplayShouldReduceMotion` over a method
channel and observe its change notification. On Linux, the same signal
SHALL set the fork's `disableAnimations` so WPE pages see it (after checking
the WPE version for the inverted-polarity bug in the table above).

Status: nothing reads either flag today.

#### Scenario: Reduce Motion on iPhone

**Given** Reduce Motion is on in iOS Settings
**When** a DNS blocklist download is in progress in App settings
**Then** its sync icon does not spin
**And** the progress is still shown

---

### Requirement: A11Y-012 - Keyboard reaches every common task on desktop

On macOS and Linux every common task SHALL be operable from the keyboard:
focus SHALL move through the chrome in order with Tab and Shift+Tab, SHALL
be able to leave a webview the same way, and dialogs SHALL close with
Escape. Switching sites, reload, find and focusing the URL bar SHALL have
shortcuts, listed in the macOS menu bar (`PlatformMenuBar`).

Status: no `Shortcuts`, `Actions` or `PlatformMenuBar` exist; the macOS menu
is the stock template. On Linux a focused webview traps the keyboard: the
fork's `CustomPlatformView._handleKeyEvent` returns `handled` for every key,
Tab included, so focus never returns to the chrome. The fix is in the fork:
let Tab out when WPE reports that focus left the page's last element, or at
least give it an escape key.

#### Scenario: Leaving the page by keyboard (Linux)

**Given** a site is focused on Linux
**When** the user presses Tab past the page's last link
**Then** focus moves to the next control of the chrome

---

### Requirement: A11Y-013 - Accessibility checks ride the release

Before a release that changes the chrome, a person SHALL run the checks for
every label answered Yes, on each device it is answered for:

- VoiceOver and Voice Control ("Show names", "Show numbers") through every
  common task;
- Larger Text at the largest accessibility size;
- Dark Interface with Increase Contrast;
- Grayscale for colour;
- Increase Contrast, Bold Text and Reduce Transparency for contrast, in both
  brightnesses;
- Reduce Motion.

Xcode's Accessibility Inspector audits a running iOS or macOS build for
labels and contrast. On Android, whatever the declaration says: TalkBack,
Switch Access (group selection) and Voice Access through every common task,
and the font size at its maximum (A11Y-016 covers the automated half).

#### Scenario: Release with a claimed label

**Given** Dark Interface is answered Yes
**When** a release is prepared
**Then** the A11Y-008 scenario was run on an iPhone and a Mac for that release

---

### Requirement: A11Y-014 - Touch targets meet the platform floor

Every tappable element of the chrome SHALL have a hit area of at least
48x48 dp on Android (`Touch_Target_Size`, Flutter's
`androidTapTargetGuideline`) and 44x44 pt on iOS (the Human Interface
Guidelines, `iOSTapTargetGuideline`). The drawn glyph may stay smaller; the
hit area may not.

Status: `TapTargets.compact` is 32 (`lib/theme/design_tokens.dart`), and
`test/design_render_matrix_test.dart` holds its widgets to that floor, which
is below both platforms'. It sizes the `HintButton` (46 call sites), the
proxy status indicator's check-again button and the tabs sheet's
expand/collapse control. Smaller still: the drawer's site menu button (about
24) and the tab counter (22x22). Flutter's tap target guidelines run in no
test.

Gate to add: `meetsGuideline(androidTapTargetGuideline)` and
`meetsGuideline(iOSTapTargetGuideline)` in widget tests of the drawer, tab
strip, app bar and settings screens, with `TapTargets.compact` raised to 48
and the render matrix floor following it.

#### Scenario: Pre-launch report

**Given** a build uploaded to a Play test track
**When** the pre-launch report runs
**Then** it lists no touch target warning on a common-task screen

---

### Requirement: A11Y-015 - A timed message is never the only way to learn something

A message that disappears on a timer SHALL NOT be the only place the app
says how to do something. Flutter keeps a `SnackBar` that has an action on
screen while `accessibleNavigation` is on (TalkBack, VoiceOver), but one
without an action still times out, and Android's "Time to take action"
setting (`AccessibilityManager.getRecommendedTimeoutMillis`) never reaches
Flutter. A snack bar that teaches SHALL either carry an action or repeat
what a labelled control or hint already says.

Status: the fullscreen exit hint (FS-002, `_enterFullscreen` in `main.dart`)
is a two-second `SnackBar` without an action. The app bar is hidden in
fullscreen, so the exits it leaves are the top-edge handle and, when shown,
the floating tabs button that opens the tab strip and its menu. Both are
unlabelled (A11Y-005), so once the hint is gone nothing a screen reader
reaches says what leaves fullscreen.

#### Scenario: Leaving fullscreen with TalkBack

**Given** TalkBack is on and a site is in fullscreen
**When** the user explores the screen by touch
**Then** a control labelled for leaving fullscreen is found and works

---

### Requirement: A11Y-016 - The pre-launch report is read every release

Before a Play release, the accessibility section of the pre-launch report for
that build SHALL be read, and every warning on a common-task screen SHALL be
fixed or recorded here with the reason it stays. The report does not stop a
release, which is why this requirement exists.

Status: never recorded. Where it cannot be run (an F-Droid-only change, no
test-track upload), Accessibility Scanner over the common tasks on one
device stands in for it.

#### Scenario: A release with a new warning

**Given** the pre-launch report for a release build lists a low-contrast
warning on the Add site screen
**When** the release is prepared
**Then** the warning is fixed, or this requirement names it and says why it
stays

---

## Order of work

By value over cost. Each item names the requirement it moves.

1. **BUG-022** (A11Y-007). Done in `4b9aa7d`, confirmed on the Android,
   macOS and Linux tiers.
2. **Names and actions** (A11Y-005): tooltips on the 13 icon buttons, both
   FABs and the corner button; `Semantics(onTap:, selected:)` on the drawer
   tile and tab chip; the theme tooltip; the structural gate. Small, and it
   unblocks VoiceOver and Voice Control on iPhone.
3. **Contrast and touch targets** (A11Y-010, A11Y-014): headers and greys to
   roles that pass, the test pair, `highContrastTheme`; `TapTargets.compact`
   to 48. These are two of Android's three quality criteria and most of what
   the pre-launch report will list.
4. **Selected site cue** (A11Y-009) and the statistics chips and bars.
5. **Reduced motion helper** (A11Y-011), including the Mac channel.
6. **Dark flash check** (A11Y-008). Then answer Dark Interface Yes.
7. **Larger Text matrix** (A11Y-006) and the fixed boxes it finds.
8. **Custom actions** for reorder and the long-press-only actions (A11Y-005).
9. **Theme shim compound queries** and the browser-tier media-feature gate
   (A11Y-003).
10. **Fork and engine**: Linux keyboard escape (A11Y-012), Linux text scale,
    reduced motion and dark mode settings (A11Y-007, A11Y-008, A11Y-011),
    Linux AT-SPI and macOS platform-view accessibility (A11Y-004). The Mac
    item needs Flutter.

## Files

- Audited: `lib/main.dart`, `lib/screens/`, `lib/widgets/`,
  `lib/services/webview.dart`, `lib/services/theme_color_scheme_shim.dart`,
  `lib/services/anti_fingerprinting_shim.dart`,
  `lib/services/desktop_mode_shim.dart`, `lib/services/page_zoom_shim.dart`,
  `lib/theme/`.
- Existing tests that already check a piece of this:
  `test/accent_theme_contrast_test.dart`,
  `test/design_tokens_validity_test.dart`,
  `test/design_render_matrix_test.dart`, `test/tabs_sheet_test.dart`,
  `test/site_permission_badges_test.dart`,
  `test/browser/theme_color_scheme_real.test.js`.
- Related specs: [webview-hints](../webview-hints/spec.md),
  [page-zoom](../page-zoom/spec.md),
  [tracking-protection](../tracking-protection/spec.md),
  [settings-hints](../settings-hints/spec.md),
  [site-permission-badges](../site-permission-badges/spec.md),
  [design-gallery](../design-gallery/spec.md).
