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
| Embedded Tor client (`tor-proxy` TOR-007) | Built-in Tor | on | `TorService.isAvailable` |
| Android's per-site proxy router (`proxy` PROXY-013) | Proxy router | on | `ProxyRouterService.isSupported`, read once at launch |
| Tabs inside a site (`inactive-tabs` TAB-012) | Site tabs | off | `_tabsEnabled` in `main.dart`, read on every use |

Outbound link routing (`link-intent-routing` LIR-013 to LIR-017) was in the group with a switch that defaulted off; it graduated with the site info sheet (`site-info-sheet`, NAV-011), which shows the site and container a routed page runs as.

#### Scenario: A feature needs both

- **GIVEN** developer mode is on and the Built-in Tor switch is off
- **WHEN** the user opens a site's proxy settings on iOS
- **THEN** Tor is not offered
- **AND** turning the switch on offers it with no restart

#### Scenario: Developer mode off closes every feature

- **GIVEN** the Built-in Tor switch is on
- **WHEN** the user turns developer mode off
- **THEN** Tor is not reachable
- **AND** turning developer mode back on makes it reachable again, with the switch still on

#### Scenario: The group appears with developer mode

- **GIVEN** an iOS build with developer mode off
- **WHEN** the user opens App settings
- **THEN** there is no Experimental group
- **AND** after unlocking developer mode the Developer section shows it, with Built-in Tor on

#### Scenario: Only what this platform can run

- **GIVEN** an Android build whose WebView reports `MULTI_PROFILE`, with developer mode on
- **WHEN** the user opens App settings
- **THEN** the Experimental group lists Proxy router, on
- **AND** it does not list Built-in Tor, which has no runtime on Android

#### Scenario: A platform with neither Tor nor the router

- **GIVEN** a Linux build with developer mode on
- **WHEN** the user opens App settings
- **THEN** there is no Experimental group

#### Scenario: The proxy router switch applies at next launch

- **GIVEN** router mode is running on Android
- **WHEN** the user turns the Proxy router switch off
- **THEN** the relay stays bound until the app restarts
- **AND** after the restart mismatched-proxy sites serialise under PROXY-008

#### Scenario: Switches survive a backup round trip

- **GIVEN** the Built-in Tor switch is off and the user exports settings
- **WHEN** that backup is imported
- **THEN** the switch is off and Tor is unreachable without a restart
