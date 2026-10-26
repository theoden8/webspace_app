# Web Extensions

## Purpose

Lets a user run browser extensions (WebExtensions, the format Chrome, Firefox and Safari share) on the sites they choose, on platforms whose WebKit can load them, with each extension confined to the site it runs on.

## ADDED Requirements

### Requirement: WEBEXT-001 - Offered only where WebKit runs extensions, as an experiment

Web extensions SHALL be reachable only on iOS 18.4+ and macOS 15.4+, and there only while developer mode and the Web extensions switch in the Experimental group are on (DEVTOOLS-011). The switch SHALL default off. Elsewhere there SHALL be no switch, no Extensions screen and no extension setting on any webview.

#### Scenario: A supported Mac with the switch on

- **GIVEN** macOS 15.4 with developer mode and Web extensions on
- **WHEN** the user opens App Settings
- **THEN** an Extensions row is shown

#### Scenario: An older system

- **GIVEN** iOS 18.3 with developer mode on
- **WHEN** the user opens App Settings
- **THEN** there is no Web extensions switch and no Extensions row

#### Scenario: Android and Linux

- **GIVEN** an Android or Linux build with developer mode on
- **WHEN** the user opens App Settings
- **THEN** there is no Web extensions switch and no Extensions row

### Requirement: WEBEXT-002 - The user imports an extension from a file; the app fetches none

App Settings > Extensions SHALL import an extension from a file the user picks: an unpacked folder (macOS), a `.zip`, a `.crx` or an `.xpi`. The app SHALL download no extension, check no store signature and update none on its own. Before adding, it SHALL show the extension's name, version, permissions and the sites it asks for.

#### Scenario: A Chrome package

- **GIVEN** a `.crx` file (version 2 or 3) holding a valid extension
- **WHEN** the user imports it
- **THEN** the package header is removed and the archive behind it is read
- **AND** the summary shows the extension's name, version and what it asks for
- **AND** the summary says the package's signature was not checked

#### Scenario: A file that is not an extension

- **GIVEN** a `.zip` with no `manifest.json` at its root
- **WHEN** the user imports it
- **THEN** nothing is added and the user is told the file holds no extension

#### Scenario: An archive entry outside the extension's folder

- **GIVEN** a `.zip` with an entry named `../evil.js` or an absolute path
- **WHEN** the user imports it
- **THEN** nothing is added and nothing is written outside the app's extension folder

#### Scenario: Removing an extension

- **GIVEN** an extension in the library that two sites switched on
- **WHEN** the user removes it
- **THEN** its files and its data on both sites are deleted, and it runs on neither

### Requirement: WEBEXT-003 - Chrome-format extensions run as far as WebKit supports their APIs

An extension written for Chrome SHALL be loaded as is, with no rewriting, through WebKit's support for the `chrome.*` and `browser.*` namespaces. What WebKit reports it could not load or does not support SHALL be shown on the extension's library entry.

#### Scenario: An extension using an API WebKit lacks

- **GIVEN** an imported extension whose manifest uses a key or API WebKit reports as unsupported
- **WHEN** the user opens its library entry
- **THEN** the entry lists what WebKit reported
- **AND** the extension is still offered to sites

### Requirement: WEBEXT-004 - An extension runs on a site only after the user switches it on there

Every extension SHALL be off on every site until the user switches it on in that site's Settings > Extensions. Switching one on SHALL first show what it asks for and that its access is limited to this site's domains. The change SHALL apply from the next webview built for the site.

#### Scenario: A new extension runs nowhere

- **GIVEN** an extension just imported
- **WHEN** any site loads
- **THEN** none of the extension's scripts runs and no background page for it starts

#### Scenario: Switching one on for a site

- **GIVEN** a site and an imported extension
- **WHEN** the user switches it on in the site's Extensions screen and confirms
- **THEN** the extension runs on that site from its next webview, and on no other site

### Requirement: WEBEXT-005 - An extension sees only the site it runs on

On a site, an extension SHALL be granted host access for the site's own domains and denied every other host, including when it asks for `<all_urls>` or for more at run time, without asking the user again. Its tab and window queries SHALL return the site's own tabs only.

#### Scenario: An extension asking for every site

- **GIVEN** an extension requesting `<all_urls>`, switched on for a site claiming `example.com` and `*.example.com`
- **WHEN** the site loads
- **THEN** the extension has access to `https://example.com/` and `https://www.example.com/`
- **AND** it has no access to `https://other.example/`

#### Scenario: Other sites are invisible

- **GIVEN** an extension switched on for site A, with site B also loaded
- **WHEN** the extension queries its tabs and windows
- **THEN** only site A's tabs are returned

#### Scenario: A run-time request for more hosts

- **GIVEN** an extension on site A
- **WHEN** it requests access to a host site A does not claim
- **THEN** the request is denied and no prompt is shown

### Requirement: WEBEXT-006 - An extension's data is the site's own

An extension's storage on a site SHALL be that site's alone, and its cookie access SHALL be the site's container. Deleting a site SHALL delete every extension's data for it. An incognito site SHALL keep no extension data across an app restart.

#### Scenario: Two sites, one extension

- **GIVEN** one extension switched on for sites A and B
- **WHEN** it stores a value on site A
- **THEN** it cannot read that value on site B

#### Scenario: Deleting a site

- **GIVEN** an extension that stored data on site A
- **WHEN** site A is deleted
- **THEN** the extension's data for site A is removed

#### Scenario: An incognito site

- **GIVEN** an incognito site where an extension stored a value
- **WHEN** the app restarts
- **THEN** the value is gone

### Requirement: WEBEXT-007 - Extensions reach no native code and no other app

An extension's messages to an application, its native-messaging connections and its `nativeMessaging` permission SHALL be refused. No app API SHALL be exposed to an extension.

#### Scenario: Native messaging

- **GIVEN** an extension that calls `runtime.sendNativeMessage` or `runtime.connectNative`
- **WHEN** the call reaches the app
- **THEN** it fails and nothing outside the extension receives it

### Requirement: WEBEXT-008 - An extension's own UI opens within its site

Each enabled extension with an action SHALL appear in the site's menu; its popup and its options page SHALL open over the site. A request to open a tab SHALL open the extension's own page over the site, a URL of the site's domains as a nested screen of the site, and nothing for any other URL. A request to open a window SHALL be refused.

#### Scenario: The action popup

- **GIVEN** an extension with an action popup, switched on for the site on screen
- **WHEN** the user picks it from the site's menu
- **THEN** its popup opens over the site

#### Scenario: The extension's own page

- **GIVEN** an extension that opens its welcome page in a new tab when first loaded on a site
- **WHEN** the site's webview is built
- **THEN** the welcome page opens over the site, with the extension's access

#### Scenario: A page of the site

- **GIVEN** an extension on a site claiming `example.com`
- **WHEN** it asks to open a tab at `https://example.com/help`
- **THEN** the page opens as a nested screen of the site

#### Scenario: Opening a tab elsewhere

- **GIVEN** an extension on a site claiming `example.com`
- **WHEN** it asks to open a tab at `https://other.example/`
- **THEN** no tab opens and the extension is told it failed

### Requirement: WEBEXT-009 - Archive-tier and kiosk sites run no extension

An archive-tier site and a kiosk site SHALL offer no extension and attach none, whatever their stored settings say (ARCH-006). Their Extensions row SHALL show the reason.

#### Scenario: An archive-tier site

- **GIVEN** an archive-tier site
- **WHEN** the user opens its Settings
- **THEN** the Extensions row is locked, naming the archive
- **AND** no extension runs on the site

### Requirement: WEBEXT-010 - Nested screens and popups run the site's extensions

A nested screen or popup a site opens SHALL run the site's extensions with the same storage and the same host limits as the site's own webview (NESTED-010).

#### Scenario: A link to another domain

- **GIVEN** an extension on a site claiming `example.com`
- **WHEN** the site opens a nested screen at `https://other.example/`
- **THEN** the nested screen has the site's extensions attached
- **AND** none of them has access to `https://other.example/`

### Requirement: WEBEXT-011 - Backups and QR shares carry no extensions

A settings backup and a site's QR share SHALL carry neither the extension library nor which sites enable an extension. An imported backup SHALL enable no extension on any site.

#### Scenario: Exporting

- **GIVEN** sites with extensions switched on
- **WHEN** the user exports settings
- **THEN** the backup names no extension

### Requirement: WEBEXT-012 - Turning the experiment off detaches every extension

With the Web extensions switch or developer mode off, no webview SHALL attach an extension and the Extensions screens SHALL be hidden. Each site's choices SHALL be kept, so turning the switch back on restores them.

#### Scenario: Off and on again

- **GIVEN** a site with an extension switched on
- **WHEN** the user turns Web extensions off, reopens the site, then turns it back on
- **THEN** the site ran with no extension while it was off
- **AND** the extension runs on the site again after it is back on
