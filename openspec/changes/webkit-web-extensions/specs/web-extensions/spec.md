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

App Settings > Extensions SHALL import an extension from a file the user picks: an unpacked folder (macOS), a `.zip`, a `.crx` or an `.xpi`, read as WEBEXT-013 says. The app SHALL download no extension and update none on its own. Before adding, it SHALL show the extension's name, version, permissions and the sites it asks for, and say when the package carried a signature the app did not check.

#### Scenario: A Chrome package

- **GIVEN** a `.crx` file holding a valid extension
- **WHEN** the user imports it
- **THEN** the summary shows the extension's name, version and what it asks for
- **AND** the summary says the package's signature was not checked

#### Scenario: A file that is not an extension

- **GIVEN** a file WEBEXT-013 refuses
- **WHEN** the user imports it
- **THEN** nothing is added and the user is told why, in the words of the refusal

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

A settings backup SHALL NOT carry the extension library: no extension's files, manifest or name. A site's QR share SHALL NOT carry which extensions the site switched on. An imported backup SHALL switch on no extension on any site, since the ids it holds name another device's library.

#### Scenario: Exporting

- **GIVEN** an extension in the library, switched on for a site
- **WHEN** the user exports settings
- **THEN** the backup holds none of the extension's files, manifest or name

#### Scenario: Importing

- **GIVEN** a backup in which a site switched an extension on
- **WHEN** the user imports it
- **THEN** the site runs no extension until the user switches one on there

### Requirement: WEBEXT-012 - Turning the experiment off detaches every extension

With the Web extensions switch or developer mode off, no webview SHALL attach an extension and the Extensions screens SHALL be hidden. Each site's choices SHALL be kept, so turning the switch back on restores them.

#### Scenario: Off and on again

- **GIVEN** a site with an extension switched on
- **WHEN** the user turns Web extensions off, reopens the site, then turns it back on
- **THEN** the site ran with no extension while it was off
- **AND** the extension runs on the site again after it is back on

### Requirement: WEBEXT-013 - A package is read from its bytes, or refused with the reason

A package SHALL be told from its bytes, never its name: a Chrome package (version 2 or 3) is read from the archive after its header, a `.zip` or `.xpi` as it is. It SHALL be refused, naming why, when it is cut short, its records disagree, an entry could land outside the extension's folder or on another entry, an entry is not what the archive declares, it passes the size limits, or its root has no readable manifest. Reading SHALL never throw.

#### Scenario: Chrome packages of both versions

- **GIVEN** a `.crx` of version 3 (a header length, then a signed header) or version 2 (a key length and a signature length, then both)
- **WHEN** it is read
- **THEN** the archive after the header is read, and the package is marked as carrying a signature the app did not check

#### Scenario: A signed Firefox package

- **GIVEN** an `.xpi` holding `META-INF/mozilla.rsa`
- **WHEN** it is read
- **THEN** it is read as a ZIP and marked as carrying a signature the app did not check

#### Scenario: An entry outside the folder

- **GIVEN** an archive with an entry named `../evil.js`, `/abs.js`, `a\b.js`, a symbolic link, `A.js` beside `a.js`, or `a` beside `a/b.js`
- **WHEN** it is read
- **THEN** it is refused, naming the entry and its problem, and nothing is inflated

#### Scenario: An entry larger than it declares

- **GIVEN** an entry declaring 1 KiB whose deflate stream makes 2 MiB
- **WHEN** it is read
- **THEN** inflating stops past 1 KiB and the package is refused as corrupt

#### Scenario: A deflate stream built to never end

- **GIVEN** an entry whose stream loops a pure Dart inflater forever
- **WHEN** it is read
- **THEN** the package is refused as corrupt, promptly

#### Scenario: Sizes past the limit

- **GIVEN** an archive whose entries declare more than 256 MiB in all
- **WHEN** it is read
- **THEN** it is refused as too large before any entry is inflated

#### Scenario: A localized name

- **GIVEN** a manifest named `__MSG_extName__` with `default_locale` `en` and `_locales/en/messages.json` naming `ExtName` `Tidy`
- **WHEN** it is read
- **THEN** the extension's name is `Tidy`

#### Scenario: Any bytes at all

- **GIVEN** random bytes, or a package with bytes changed or cut at random
- **WHEN** it is read
- **THEN** it is read or refused, the same way each time, and nothing is thrown

### Requirement: WEBEXT-014 - An extension's hosts are what it asked for within the site

On a site, an extension SHALL be granted the pages both a pattern it asked for and a pattern the site's claims cover name, and no other. An exact host claim covers that host; a base-domain claim, the domain and its subdomains; a wildcard claim, its subdomains and the bare host, which a match pattern cannot leave out. A claim with a port covers nothing. Only http and https pages are granted, matched on a dot boundary.

#### Scenario: Every site asked for, one site claimed

- **GIVEN** an extension asking for `<all_urls>` on a site claiming base domain `example.com`
- **WHEN** its grants are planned
- **THEN** it is granted `*://*.example.com/*` and nothing else

#### Scenario: A narrower request stays narrow

- **GIVEN** an extension asking for `https://mail.example.com/*` on the same site
- **WHEN** its grants are planned
- **THEN** it is granted `https://mail.example.com/*`

#### Scenario: A host that only ends in the domain

- **GIVEN** an extension asking for `*://*.evilexample.com/*` on the same site
- **WHEN** its grants are planned
- **THEN** it is granted nothing

#### Scenario: A claim with a port

- **GIVEN** a site claiming `localhost:8080` and an extension asking for `http://localhost:8080/*`
- **WHEN** its grants are planned
- **THEN** it is granted nothing

### Requirement: WEBEXT-015 - An extension holds only the permissions the app allows

An extension SHALL be granted only the API permissions it asked for that the app lets an extension hold (storage, tabs, scripting, alarms, context menus, cookies, declarative net request, web navigation, web request, clipboard write, active tab, unlimited storage), never `nativeMessaging` or any other.

#### Scenario: Native messaging asked for

- **GIVEN** an extension asking for `storage`, `tabs`, `scripting`, `nativeMessaging`, `debugger` and `downloads`
- **WHEN** its grants are planned
- **THEN** it is granted `storage`, `tabs` and `scripting`

### Requirement: WEBEXT-016 - A site's webviews attach what the site switched on, where it may

A site's webviews SHALL attach the extensions the site switched on that are still in the library, each with its WEBEXT-014 and WEBEXT-015 grants, keeping their data unless the site is incognito. They SHALL attach none, and name why, when the system cannot run extensions, the experiment is off, the site is archived or a kiosk, or none is switched on, checked in that order.

#### Scenario: An ordinary site

- **GIVEN** a site that switched on one extension, on a supported system with the experiment on
- **WHEN** its webviews' extensions are planned
- **THEN** that extension attaches, keeping its data

#### Scenario: An incognito site

- **GIVEN** the same site set incognito
- **WHEN** its webviews' extensions are planned
- **THEN** the extension attaches without keeping data

#### Scenario: An archived or kiosk site

- **GIVEN** the same site in an archive, or set as a kiosk
- **WHEN** its webviews' extensions are planned
- **THEN** none attaches, and the reason names the archive or the kiosk

#### Scenario: An extension removed from the library

- **GIVEN** a site whose only switched-on extension is no longer in the library
- **WHEN** its webviews' extensions are planned
- **THEN** none attaches

