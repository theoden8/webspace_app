# Site Settings QR — blocker masks in the review gate

## MODIFIED Requirements

### Requirement: QR-008 - Receiver Review Gate

A QR payload is authored by whoever printed the code and chooses the new
site's URL, its display name, its proxy, and the state of every per-site
protection. The receiver SHALL NOT create a site from one until the user
has seen those choices and accepted them.

The gate SHALL live in `_addSite`'s `qrSettings` branch so that **both**
entry points cross it: the in-app scanner / paste dialog
(`AddSiteScreen._addByQr` → `showSiteSettingsQrApplyDialog`) and the
`webspace://qr/` deep link handled by `_handleShareIntent`. The dialog
SHALL show the payload's `initUrl`, its `name`, its proxy address when the
payload sets a non-DEFAULT proxy, the protections the payload switches off
(Tracking Protection, ClearURLs, DNS Blocklist, Content Blocker, LocalCDN,
Block auto-redirects) and the permissions or modes it switches on
(third-party cookies, Notifications, Background audio, Kiosk mode,
Geolocation), and SHALL require an explicit accept.

The blockers can also be weakened without either toggle moving, so the
protections-switched-off list SHALL also name:

- **Blocklist level**, when the payload's `dnsBlockLevel` is below the
  app-wide level;
- **Filter lists**, when the payload's `disabledFilterLists` is non-empty.

Both are relaxations the payload's author chose for the receiver, and
neither shows up in any boolean the dialog already reports.

A site created from a deep link SHALL NOT be activated: `_registerNewSite`
is called with `activate: false`, so the site is added to the list and
persisted but `_setCurrentIndex` is not called and the current site keeps
the screen. A site created from the in-app scanner IS activated — the user
went looking for it.

The `linkHandlingEnabled` master switch (LIR-008) SHALL be evaluated
BEFORE the `webspace://qr/` branch, so turning link handling off drops QR
deep links along with every other inbound URL.

#### Scenario: Deep-link payload is reviewed, not applied

**Given** link handling is enabled
**And** another app opens `webspace://qr/site/v1/<payload>` where the
payload sets `trackingProtectionEnabled: false` and a SOCKS5 proxy
**When** `_handleShareIntent` decodes it and calls
`_addSite(deepLinkQrSettings: decoded)`
**Then** a review dialog is shown naming the URL, the name, the proxy
address, and "Tracking Protection" as a protection being turned off
**And** no `WebViewModel` exists until the user accepts

#### Scenario: A payload that only weakens the blockers is still named

**Given** the app-wide DNS level is Pro
**And** a payload leaves every protection toggle on but sets
`dnsBlockLevel: 1` and `disabledFilterLists: ["easylist"]`
**When** the review dialog is shown
**Then** it names "Blocklist level" and "Filter lists" among the
protections the payload turns off

#### Scenario: Declining the review creates nothing

**Given** the review dialog is shown
**When** the user cancels
**Then** `_registerNewSite` is not called
**And** `_webViewModels` is unchanged

#### Scenario: Deep-link site does not take the screen

**Given** the user accepts the review dialog for a deep-link payload
**When** `_registerNewSite(model, activate: false)` runs
**Then** the model is appended to `_webViewModels` and persisted
**And** `_setCurrentIndex` is NOT called, so the currently-visible site
stays visible

#### Scenario: Link handling off drops the QR deep link

**Given** `linkHandlingEnabled` is false
**When** a `webspace://qr/` URL arrives
**Then** it is dropped with the same "link handling disabled" log line as
any other inbound URL
**And** `SiteSettingsQrCodec.decode` is not reached
