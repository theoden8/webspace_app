# Developer Tools

## MODIFIED Requirements

### Requirement: DEVTOOLS-011 - Experimental Features

A feature that ships before it is finished SHALL be reachable only while developer mode is on (DEVTOOLS-010) **and** its own switch in the Experimental group is on. The switch only narrows developer mode: with developer mode off no experimental feature is reachable, whatever its switch reads, so "is this feature reachable" keeps one answer.

- **The group.** App settings' Developer section SHALL show an **Experimental** group while developer mode is on, listing one switch per experimental feature that this platform can run. With no such feature on the platform, the group SHALL NOT be shown. Each switch carries its explanation behind a `HintButton` (HINT-001).
- **The switches keep their positions.** Turning developer mode off SHALL leave every switch as it was, so turning developer mode back on restores the same set of features.
- **Reading it.** `ExperimentalFeaturesService.instance.isEnabled(feature)` (`lib/services/experimental_features_service.dart`) is the single reader. The rule itself, developer mode and the switch, is the pure `experimentalFeatureEnabled`.
- **Persistence.** Each switch is a user-facing global pref registered in `AppPref`, so it round-trips export and import, and the service SHALL be re-read after an import.
- **Defaults.** A feature that developer mode alone opened before this group existed SHALL default its switch on, so an upgrade does not turn it off for a user who had it. A new feature SHALL default off.
- **Leaving the group.** A feature that graduates SHALL remove its switch and stop reading this gate; one that is dropped SHALL remove its switch with its code.

The features are:

| Feature | Switch | Default | Gate |
|---|---|---|---|
| Webspace icon groups (`webspaces` WEBSPACE-002) | Alternative design | off | `WebSpacePage`, read on build and rebuilt when the switch or developer mode changes |
| Android's texture page rendering (`webview-pause-lifecycle` PAUSE-032) | Texture page rendering | off | `WebViewFactory.hybridComposition`, read once at launch |
| Linux: the filter lists' network rules compiled into WebKit content rule lists (`content-blocker` CB-020) | WebKit content blocking | off | `ContentBlockerService._syncRuleLists`, read on every engine rebuild and when the switch or developer mode changes |
| iOS 18.4+ and macOS 15.4+: browser extensions the user imports, switched on per site (`web-extensions` WEBEXT-001) | Web extensions | off | `WebViewModel.sitePosture`, read when a site's webview is built, and the App Settings and site Settings screens, read when they are built |

Outbound link routing (`link-intent-routing` LIR-013 to LIR-017) was in the group with a switch that defaulted off; it graduated with the site info sheet (`site-info-sheet`, NAV-011), which shows the site and container a routed page runs as. Page icons fetched from the links a page declares on iOS, macOS and Linux (`icon-fetching` ICON-013) were in the group with a switch that defaulted off; they graduated to the default there, and the group's Site icons only switch took the slot.

A site's icon taken only from the site (`icon-fetching` ICON-014), with no third-party icon service and, on Android, the declared links in place of WebView's icon, was in the group with a Site icons only switch that defaulted off. Its first half graduated: no platform asks a third-party icon service. Android keeps the icon its WebView reports (ICON-009), and the switch's pref (`experimentalSiteIconsOnly`, written by v0.3.3 to v0.3.5) is no longer read.

Android's per-site proxy router (`proxy` PROXY-013) was in the group with a Proxy router switch that defaulted on, since developer mode alone had run it before the group existed; it graduated, and runs wherever the WebView reports `MULTI_PROFILE` and a site is proxied, with developer mode on or off. The switch moved to App settings' Network screen, keeps its stored value, and is offered with developer mode on or off.

The proxy library and the connection indicator (`proxy` PROXY-030, PROXY-031) were in the group with a Saved proxies switch that defaulted off; they graduated, and are offered with developer mode on or off.

Tabs inside a site (`inactive-tabs` TAB-012), and web search, whose results are tabs (`link-intent-routing` LIR-029), were in the group with a Site tabs switch that defaulted off; they graduated. Tabs answer to each site's own Tabs switch (TAB-013) alone, and web search is offered with developer mode on or off.

The embedded Tor client (`tor-proxy` TOR-007) was the first feature in the group, with a Built-in Tor switch that defaulted on; it graduated, and Tor is now offered wherever the platform has the runtime, with developer mode on or off.

Tor sites through a tor already running on the device (`tor-proxy` TOR-025) were in the group with a Tor (external) switch that defaulted off; they graduated. The switch moved to App settings' Network screen, keeps its stored value, and is offered with developer mode on or off.

WebKit content rule lists on iOS and macOS (`content-blocker` CB-020) were in the group under the WebKit content blocking switch; they graduated there, and attach whenever a site's content blocker runs. The switch stays for Linux, where the lists are still an experiment, and is offered only there.

Sign-in popups (`nested-url-blocking` NESTED-014) were in the group under the Sign-in popups switch; they graduated on iOS, macOS and Linux first and then on Android, and follow the app's and each site's Sign-in popups switches in Behaviour with developer mode on or off. The switch's pref (`experimentalSignInPopups`) is no longer read.

#### Scenario: The group appears with developer mode

- **GIVEN** an iOS build with developer mode off
- **WHEN** the user opens App settings
- **THEN** there is no Experimental group
- **AND** after unlocking developer mode the Developer section shows it, with Alternative design off and no Tor, WebKit content blocking or Sign-in popups switch

#### Scenario: Only what this platform can run

- **GIVEN** an Android build whose WebView reports `MULTI_PROFILE`, with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists Alternative design and Texture page rendering, off

#### Scenario: A platform without the router

- **GIVEN** a Linux build with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists Alternative design and WebKit content blocking, off

#### Scenario: Alternative design is opt-in and follows the gate live

- **GIVEN** the Alternative design switch has never been enabled
- **WHEN** the app opens with developer mode on or off
- **THEN** the existing webspace list, app bar, add-site button, and drawer are shown
- **AND** enabling both developer mode and Alternative design replaces the home screen with the grouped site launcher, without restarting
- **AND** turning either off restores the existing interface without changing sites, webspaces, or selection
- **AND** turning developer mode back on restores the grouped site launcher if its switch is still on

#### Scenario: Switches survive a backup round trip

- **GIVEN** the Alternative design switch is on and the user exports settings
- **WHEN** that backup is imported
- **THEN** the switch is on without a restart

#### Scenario: Web extensions only where WebKit runs them

- **GIVEN** a macOS 15.4 build with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists Web extensions, off
- **AND** a build on macOS 15.3, iOS 18.3, Android or Linux shows no Web extensions switch
