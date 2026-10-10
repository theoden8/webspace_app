## ADDED Requirements

### Requirement: INC-008 - A Restart Wipes The Container, Not The Tabs

With tabs on, an incognito site's tab list SHALL survive an app restart as
any other site's does: each tab's address, title and place in the tree. What a
restart SHALL wipe is the site's container (INC-005), its cookies (INC-001) and
every tab's back stack (INC-002), so every tab reloads signed out with no
history. The site SHALL land on a tab at home, as Always open Home lands it
(TAB-014, AOH-005). The site-level `currentUrl` and `pageTitle` SHALL still be
dropped (INC-003).

#### Scenario: Incognito relaunch keeps the tabs

- **GIVEN** an incognito Wikipedia site with tabs, on an article, with a parked tab at another article
- **WHEN** the app is killed and relaunched
- **THEN** both articles are still listed in Wikipedia's tabs, and Wikipedia shows a tab at `initUrl`
- **AND** opening either article loads it with no history and none of the last session's cookies or storage
- **AND** no `webview_state/<siteId>.*.enc` file exists
