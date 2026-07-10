## ADDED Requirements

### Requirement: ICON-009 - Offline Icon Read Path

The icon service SHALL provide an offline read path that resolves an icon for a URL without ever contacting the outbound HTTP factory. It SHALL consult, in order, the committed bundled assets, the in-memory caches (`_faviconCache`, `_svgContentCache`), and the persisted disk cache. On a miss it SHALL resolve to a placeholder and complete, and SHALL NOT fall through to a network fetch. The offline read path is distinct from a fail-closed `OutboundClientBlocked` result: "told not to fetch" and "cannot fetch safely" are separate concepts, and the offline path simply never calls `outboundHttp.clientFor()`.

#### Scenario: Offline read with bundled asset

**Given** a URL whose host has a committed bundled icon asset
**When** the icon is requested via the offline read path
**Then** the bundled asset is returned
**And** `outboundHttp.clientFor()` is not called

#### Scenario: Offline read miss resolves to placeholder

**Given** a URL with no bundled asset and no cached icon
**When** the icon is requested via the offline read path
**Then** a placeholder is resolved
**And** no network request is issued

#### Scenario: Offline read never blocks on proxy

**Given** any proxy configuration, including one that would yield `OutboundClientBlocked`
**When** the icon is requested via the offline read path
**Then** proxy resolution is not consulted
**And** the result depends only on bundled assets and caches

### Requirement: ICON-010 - Add-Time Cache Warming

When a user adds a suggestion or a custom site, the network-capable fetch path SHALL fetch the icon and store it in the shared caches, so that a subsequent offline read for that URL resolves from cache in the same session.

#### Scenario: Adding a custom site warms the offline read

**Given** the offline read path returns a placeholder for example.com (no bundled asset, cold cache)
**When** the user adds example.com and its icon is fetched and stored
**Then** a subsequent offline read for example.com resolves the fetched icon from cache
**And** that offline read makes no network request

### Requirement: ICON-011 - Shared Cache Between Read Paths

The offline read path and the network-capable fetch path SHALL read and write the same module-level caches. There SHALL be no forked or instance-private icon cache, so writes from one path are visible to reads from the other without a restart.

#### Scenario: Network write visible to offline read in-session

**Given** the network path has fetched and cached an icon for a URL
**When** the offline read path is invoked for the same URL
**Then** it returns the cached icon
**And** it issues no network request
