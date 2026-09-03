## MODIFIED Requirements

### Requirement: DEVTOOLS-010 - Developer Mode Gate

The app SHALL carry an app-global **developer mode** flag, off by default, that gates two kinds of thing: affordances which exist to diagnose the app rather than to use it, and **features that are shipped but not finished**.

Diagnostics accumulate. A blank-screen repaint action (`webview-pause-lifecycle` PAUSE-028) is the first, and each one is a control an ordinary user cannot interpret sitting in a menu they open to refresh a page. Hiding them behind a debug build is not an option either: the users who hit these bugs run release builds, and the report is worth nothing if they cannot reach the tool. So the flag is reachable on every build and reached only deliberately.

The second kind arrived with `tor-proxy` TOR-007. An embedded Tor client
whose bootstrap interstitial is not built leaves a site sitting on the
fail-closed blank page with nothing explaining why: complete enough to
exercise on hardware, not complete enough to hand an ordinary user. The
alternatives were worse. Holding the code out of the branch loses the
review and the CI coverage; adding a second "experimental features" flag
gives two answers to "is this feature reachable" and invites a third. So
the same flag carries both meanings, and the reason it can is the reason
it exists: it is reachable on release builds, which is where the people
who can report on an unfinished feature actually are.

A feature gated this way SHALL name, in its own requirement, what has to
land before the gate comes off, so the gate is a recorded step rather
than a place features go to be forgotten. TOR-007 names TOR-013's
bootstrap surface.

- **The gesture.** App Settings SHALL show a **Version** row in the About section carrying `version+buildNumber`. Seven taps on it turn developer mode on, the Android developer-options convention, so the gesture needs no discovery mechanism of its own. The first two taps SHALL say nothing (a stray double tap is not a discovery), the third through sixth SHALL show the remaining count, and the seventh SHALL confirm. Each message SHALL replace the previous one rather than queue behind it, or the countdown lags several taps behind the finger. Tapping while already on SHALL say so and SHALL NOT count. Counting logic lives in `DeveloperUnlockEngine` (`lib/services/developer_unlock_engine.dart`), not in the widget.
- **Turning it off.** Once on, the Developer section SHALL show a **Developer mode** switch, so the state is visible and reversible without repeating the gesture. The switch is hidden while off: a control whose only purpose is to undo a hidden gesture has nothing to say before the gesture happens.
- **Reading it.** `DeveloperModeService.instance.enabled` (`lib/services/developer_mode_service.dart`) is the single reader. It is a service rather than a widget parameter because both webview-hosting screens consult it and it is **not** a per-site setting: routing it through the per-site `launchUrl` pipeline would misfile it as one. A `PopupMenuButton`'s `itemBuilder` runs each time the menu opens, so a flip takes effect with no rebuild and no restart.
- **Persistence.** The flag is a user-facing global pref: it SHALL be registered in `kExportedAppPrefs` (`kDeveloperModeKey`) so it round-trips export/import, and the service SHALL be re-read after an import, which writes the raw key through the registry behind the service's cache.

#### Scenario: Unlocking developer mode

**Given** developer mode is off
**When** the user taps the Version row in App Settings seven times
**Then** the last five taps count down and the seventh confirms developer mode is on
**And** the Developer section grows a Developer mode switch that turns it back off

#### Scenario: A stray tap says nothing

**Given** developer mode is off
**When** the user taps the Version row twice
**Then** no message is shown, because the gesture has not been recognisably started

#### Scenario: The flag survives a backup round trip

**Given** developer mode is on and the user exports settings
**When** that backup is imported
**Then** developer mode is on and the service reflects it without a restart
