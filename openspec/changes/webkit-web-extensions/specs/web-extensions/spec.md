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

### Requirement: WEBEXT-002 - The user adds an extension from a file or a link; the app downloads only what the user asked for

App Settings > Extensions SHALL import an extension from a file the user picks: an unpacked folder (macOS), a `.zip`, a `.crx` or an `.xpi`, read as WEBEXT-013 says, or from a link as WEBEXT-017 says. The app SHALL download a package only when the user adds or updates an extension, or where WEBEXT-019's switch lets an update install without asking; checking for an update (WEBEXT-018) downloads none. Before adding, it SHALL show the extension's name, version, permissions and the sites it asks for, and say when the package carried a signature the app did not check. An added extension SHALL stay until the user removes it: a launch SHALL delete only the files no library entry names, and none when it cannot read the library whole.

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

#### Scenario: An app update

- **GIVEN** an extension in the library
- **WHEN** the app is updated and launched again
- **THEN** the extension and its files are still in the library

### Requirement: WEBEXT-003 - Chrome-format extensions run as far as WebKit supports their APIs

An extension written for Chrome SHALL be loaded as is, with no rewriting, through WebKit's support for the `chrome.*` and `browser.*` namespaces. What WebKit reports it could not load or does not support SHALL be shown on the extension's library entry.

#### Scenario: An extension using an API WebKit lacks

- **GIVEN** an imported extension whose manifest uses a key or API WebKit reports as unsupported
- **WHEN** the user opens its library entry
- **THEN** the entry lists what WebKit reported
- **AND** the extension is still offered to sites

### Requirement: WEBEXT-004 - An extension runs on a site only after the user switches it on there or for every site

Each extension SHALL have a default for every site, off when it is added. A site SHALL follow that default until it sets its own choice in its Settings > Extensions, where a following switch is shown dimmed and a long press makes the shown value the site's own (BEHAV-007). Switching the default on SHALL first show what the extension asks for and that on each site it reaches only that site's domains; switching it on for one site SHALL first show what it gets there. An archive-tier or kiosk site runs none whatever either says (WEBEXT-009). A change SHALL apply from the next webview built for the site.

#### Scenario: A new extension runs nowhere

- **GIVEN** an extension just imported
- **WHEN** any site loads
- **THEN** none of the extension's scripts runs and no background page for it starts

#### Scenario: Switching one on for a site

- **GIVEN** a site and an imported extension
- **WHEN** the user switches it on in the site's Extensions screen and confirms
- **THEN** the extension runs on that site from its next webview, and on no other site

#### Scenario: On for every site, off for one

- **GIVEN** an extension whose default the user switched on and confirmed, and a site that switched it off for itself
- **WHEN** sites load
- **THEN** it runs on every site that follows the default, and not on that site

#### Scenario: A site's choice from an earlier version

- **GIVEN** a site saved by a version that kept only a set of switched-on extensions
- **WHEN** it is read
- **THEN** each extension in that set is the site's own choice, on, and every other follows its default

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

### Requirement: WEBEXT-011 - A backup carries extensions only as the user chooses; a QR share carries none

Exporting settings SHALL ask how to carry the extension library, naming the size each choice adds: leave them out (the default); as references, each extension's name, version, source (WEBEXT-017) and a fingerprint of its files; or with their files, each extension's package. Importing references SHALL relink each to an extension in this device's library with the same fingerprint, and offer to add the rest again from their sources. Importing files SHALL add each extension whose fingerprint the library lacks, after showing the WEBEXT-002 summary of all of them at once. A site SHALL keep its choices only for the extensions the import linked or added, and an extension's default for every site SHALL come back off. A site's QR share SHALL NOT carry which extensions the site switched on.

#### Scenario: Exporting

- **GIVEN** an extension in the library, switched on for a site
- **WHEN** the user exports settings and keeps the default choice
- **THEN** the backup holds none of the extension's files, manifest or name

#### Scenario: Each choice names its size

- **GIVEN** a library of two extensions whose packages are 1.2 MB and 300 KB
- **WHEN** the user exports settings
- **THEN** the choices say that references add under a kilobyte and files add about 2 MB, the packages as the backup's text holds them

#### Scenario: Files restored on another device

- **GIVEN** a backup exported with files, in which a site switched one of its extensions on
- **WHEN** it is imported on a device whose library is empty and the user accepts the summary
- **THEN** the extension is in the library, the site runs it, and its default for every site is off

#### Scenario: Importing without extensions

- **GIVEN** a backup exported leaving extensions out, in which a site switched an extension on
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

### Requirement: WEBEXT-017 - An extension added from a link keeps its source

App Settings > Extensions SHALL add an extension from a link to its addons.mozilla.org listing or to its GitHub repository or one of its releases. The app SHALL read the source's latest release and download its package: on addons.mozilla.org the current version's file; on GitHub an asset ending in `.crx`, `.zip` or `.xpi`, the user picking one where there are several, `.crx` offered first. It SHALL then show the WEBEXT-002 summary before adding. The entry SHALL keep its source, and for GitHub what the picked asset's name looks like without its version, so an update picks the same kind of file. Any other link, or a release with no package, SHALL be refused saying why.

#### Scenario: A listing on addons.mozilla.org

- **GIVEN** the link `https://addons.mozilla.org/en-US/firefox/addon/adnauseam/`
- **WHEN** the user adds from it
- **THEN** the current version's `.xpi` is downloaded and summed up, and the entry names addons.mozilla.org as its source

#### Scenario: A GitHub release with a Chrome and a Firefox package

- **GIVEN** a repository whose latest release has `ext-2.1.0.crx` and `ext-2.1.0.xpi`
- **WHEN** the user adds from the repository's link
- **THEN** the `.crx` is offered first, and the entry remembers it picked a `.crx` named like `ext-*.crx`

#### Scenario: A link to anything else

- **GIVEN** a link to a page that is neither a listing nor a repository
- **WHEN** the user adds from it
- **THEN** nothing is downloaded and the user is told the link is not one the app reads

### Requirement: WEBEXT-018 - Updates are checked; one installs when the user asks

For each extension with a source the app SHALL check the source's latest release when the user asks, and at most once a day only where the user switched daily checks on. Daily checks SHALL be off by default: until the user switches them on or asks for a check, the app SHALL send an extension's source no request it did not add the extension with. A check SHALL download no package, and SHALL mark the entry when that release's version is newer than the installed one, comparing versions part by part as browsers do. Installing an update SHALL replace the extension's files and keep its id, so every site that runs it keeps it, with its data. An update whose manifest asks for a permission or a host the installed version did not SHALL show what it adds and install only once the user accepts.

#### Scenario: Daily checks off

- **GIVEN** an extension added from a link, and daily checks off, as they are by default
- **WHEN** the app launches and the user opens App Settings > Extensions
- **THEN** no request reaches the extension's source

#### Scenario: A newer release

- **GIVEN** an extension at version 1.9 whose source's latest release is 1.10
- **WHEN** the user asks for a check, or the daily check runs with daily checks on
- **THEN** its entry says 1.10 is available

#### Scenario: An update keeps the sites

- **GIVEN** an extension switched on for two sites, with data on both
- **WHEN** the user installs its update
- **THEN** both sites run the new version and keep their data

#### Scenario: An update that asks for more

- **GIVEN** an update whose manifest adds the `cookies` permission
- **WHEN** the user installs it
- **THEN** the app shows that it adds `cookies`, and installs nothing until the user accepts

### Requirement: WEBEXT-019 - Search, and installs without asking, only outside the App Store

A build installed outside the App Store (macOS without a Mac App Store receipt) SHALL offer, as a search bar at the top of App Settings > Extensions and only while its own Experimental switch (Extension search, off by default) is on, a search of addons.mozilla.org whose results add as WEBEXT-017 does and say whether WebKit is expected to run each (works, partly, unknown) without hiding any, and a switch that installs an update asking for nothing new, without asking, as soon as a check (WEBEXT-018) finds it. An App Store build (iOS, and macOS with a receipt) SHALL offer neither: App Review Guidelines 3.2.2(i) rejects an in-app collection of extensions and 2.5.2 code the app downloads on its own. The search SHALL be compiled only into a build made with `--dart-define=WEBSPACE_EXTENSION_SEARCH=true`: a build made without it, as every App Store build is, SHALL carry none of the search's code and offer neither its bar nor its switch, wherever it was installed from, and signing a build for the Mac App Store SHALL refuse one that carries it.

#### Scenario: A build from the App Store

- **GIVEN** the app installed from the App Store
- **WHEN** the user opens App Settings > Extensions
- **THEN** there is no search and no switch to install updates without asking

#### Scenario: A build made without the search

- **GIVEN** a build made without `--dart-define=WEBSPACE_EXTENSION_SEARCH=true`, installed from outside the App Store
- **WHEN** the user opens App Settings > Developer > Experimental and App Settings > Extensions
- **THEN** there is no Extension search switch and no search bar, and the build's binary holds none of the search's code

#### Scenario: Search behind its switch

- **GIVEN** a build installed outside the App Store, with Extension search off in App Settings > Developer > Experimental, as it is by default
- **WHEN** the user opens App Settings > Extensions
- **THEN** there is no search, and the switch to install updates without asking is still there

#### Scenario: A search result WebKit runs only in part

- **GIVEN** a build installed outside the App Store, and a search result whose manifest asks for `webRequestBlocking`
- **WHEN** the results show
- **THEN** that result is labelled as running in part, and is still offered

