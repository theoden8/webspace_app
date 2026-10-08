## ADDED Requirements

### Requirement: BEHAV-006 - Search group

While web search is reachable (LIR-029: the Site tabs gate), the Behaviour screen SHALL end with a "Search" group, after "Link handling", holding three rows; while it is not, the group SHALL be absent and the site's stored search fields SHALL be kept. Each row's explanation SHALL sit behind a `HintButton` on its title (HINT-001) and its subtitle SHALL name state only.

- **Search address** (LIR-028): subtitle the site's effective address, its own `searchAddress`, else the one its host is known for, else the one its pages declared (LIR-035), else the one the site search list names (LIR-036), else "Not configured". Tapping it opens a dialog with the address field, validated as LIR-028 requires, and a "Searches the whole web" switch; its Reset button clears `searchAddress` back to the known address and turns `searchesWeb` off.
- **Default search from this site** (LIR-029): subtitle the name of `searchDefault`, or "App default". Tapping it lists "App default" and the site's candidate web search sites, each with its siteId and container colour beneath its name (LIR-029, Telling sites apart).
- **Search sites offered** (LIR-029): subtitle the names in `searchSites`, or "All". Tapping it opens a checkbox per candidate web search site, each with its siteId and container colour beneath its name. Picking a list that leaves out `searchDefault` SHALL clear `searchDefault`, so the site falls back to the app default rather than preselect a site it no longer offers.

All four fields SHALL ride `SiteBehaviourValues`, so they are in the settings screen's dirty-snapshot diff and are saved with the rest of site settings (BUG-006, EDIT-009).

#### Scenario: A known site shows its address

- **GIVEN** a GitHub site with no `searchAddress`
- **WHEN** the Behaviour screen opens
- **THEN** the Search address row reads `https://github.com/search?q=%s`
- **AND** Default search from this site reads "App default" and Search sites offered reads "All"

#### Scenario: Reset returns to the known address

- **GIVEN** GitHub's `searchAddress` is `https://github.com/search?type=code&q=%s`
- **WHEN** the user opens Search address and taps Reset
- **THEN** `searchAddress` is cleared and the row reads `https://github.com/search?q=%s`

#### Scenario: A list that drops the default clears it

- **GIVEN** a site's default search is Kagi
- **WHEN** the user limits its search sites to DuckDuckGo
- **THEN** its default search reads "App default"

#### Scenario: Leaving without saving discards search edits

- **GIVEN** the user changes the Search address on the Behaviour screen and goes back
- **WHEN** they leave site settings
- **THEN** they are asked to discard the change
