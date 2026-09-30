## ADDED Requirements

### Requirement: DEVTOOLS-011 - Experimental Features

A feature that ships before it is finished SHALL be reachable only while developer mode is on (DEVTOOLS-010) **and** its own switch in the Experimental group is on. The switch only narrows developer mode: with developer mode off no experimental feature is reachable, whatever its switch reads, so "is this feature reachable" keeps one answer.

- **The group.** App settings' Developer section SHALL show an **Experimental** group while developer mode is on, listing one switch per experimental feature that this platform can run. With no such feature on the platform, the group SHALL NOT be shown. Each switch carries its explanation behind a `HintButton` (HINT-001).
- **The switches keep their positions.** Turning developer mode off SHALL leave every switch as it was, so turning developer mode back on restores the same set of features.
- **Reading it.** `ExperimentalFeaturesService.instance.isEnabled(feature)` (`lib/services/experimental_features_service.dart`) is the single reader. The rule itself, developer mode and the switch, is the pure `experimentalFeatureEnabled`.
- **Persistence.** Each switch is a user-facing global pref registered in `kExportedAppPrefs`, so it round-trips export and import, and the service SHALL be re-read after an import.
- **Defaults.** A feature that developer mode alone opened before this group existed SHALL default its switch on, so an upgrade does not turn it off for a user who had it. A new feature SHALL default off.
- **Leaving the group.** A feature that graduates SHALL remove its switch and stop reading this gate; one that is dropped SHALL remove its switch with its code.

The features are:

| Feature | Switch | Default | Gate |
|---|---|---|---|
| Android's per-site proxy router (`proxy` PROXY-013) | Proxy router | on | `ProxyRouterService.isSupported`, read once at launch |
| A site's icon taken only from the site: no third-party icon service, and on Android the declared links in place of WebView's icon (`icon-fetching` ICON-014) | Site icons only | off | `publicIconServicesAllowed` in `icon_service.dart`, read on every icon fetch; `pageIconSource` in `site_icon_fetcher.dart`, read when a site's webview is created |
| Android's texture page rendering (`webview-pause-lifecycle` PAUSE-032) | Texture page rendering | off | `WebViewFactory.hybridComposition`, read once at launch |
| Tabs inside a site (`inactive-tabs` TAB-012) | Site tabs | off | `_tabsEnabled` in `main.dart`, read on every use |
| The proxy library and the connection indicator (`proxy` PROXY-030, PROXY-031) | Saved proxies | off | The App Settings row and the library entries in every proxy picker (`offerLibrary`), and the site info sheet's Connection row, read on every build. A setting already on the library keeps resolving and keeps its entry, so switching off never moves a site's traffic |

Outbound link routing (`link-intent-routing` LIR-013 to LIR-017) was in the group with a switch that defaulted off; it graduated with the site info sheet (`site-info-sheet`, NAV-011), which shows the site and container a routed page runs as. Page icons fetched from the links a page declares on iOS, macOS and Linux (`icon-fetching` ICON-013) were in the group with a switch that defaulted off; they graduated to the default there, and the group's Site icons only switch took the slot.

The embedded Tor client (`tor-proxy` TOR-007) was the first feature in the group, with a Built-in Tor switch that defaulted on; it graduated, and Tor is now offered wherever the platform has the runtime, with developer mode on or off.

#### Scenario: A feature needs both

- **GIVEN** developer mode is on and the Site tabs switch is off
- **WHEN** the user opens a site
- **THEN** it shows one page, with no tabs
- **AND** turning the switch on offers tabs with no restart

#### Scenario: Developer mode off closes every feature

- **GIVEN** the Site tabs switch is on
- **WHEN** the user turns developer mode off
- **THEN** tabs are not reachable
- **AND** turning developer mode back on makes them reachable again, with the switch still on

#### Scenario: The group appears with developer mode

- **GIVEN** an iOS build with developer mode off
- **WHEN** the user opens App settings
- **THEN** there is no Experimental group
- **AND** after unlocking developer mode the Developer section shows it, with Site tabs off and no Tor switch

#### Scenario: Only what this platform can run

- **GIVEN** an Android build whose WebView reports `MULTI_PROFILE`, with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists Proxy router, on, and Texture page rendering, Site icons only and Site tabs, off

#### Scenario: A platform without the router

- **GIVEN** a Linux build with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists only Site icons only and Site tabs, both off

#### Scenario: Site icons only starts off

- **GIVEN** an Android build with developer mode on and the Site icons only switch never touched
- **WHEN** a site's icon is fetched
- **THEN** Google's and DuckDuckGo's icon services are asked, and the site's webview reports its icon
- **AND** after the user turns Site icons only on, neither service is asked, and a site opened afterwards gets the icon its page declares

#### Scenario: The proxy router switch applies at next launch

- **GIVEN** router mode is running on Android
- **WHEN** the user turns the Proxy router switch off
- **THEN** the relay stays bound until the app restarts
- **AND** after the restart mismatched-proxy sites serialise under PROXY-008

#### Scenario: Switches survive a backup round trip

- **GIVEN** the Site icons only switch is on and the user exports settings
- **WHEN** that backup is imported
- **THEN** the switch is on without a restart
