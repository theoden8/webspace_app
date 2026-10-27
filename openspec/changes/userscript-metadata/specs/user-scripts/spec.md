# User Scripts

## MODIFIED Requirements

### Requirement: US-002 - Script Injection

Enabled user scripts SHALL be injected into the webview at the configured injection time, on the pages their header names (US-009). The injection time is the header's when it sets one (US-010).

#### Scenario: Inject at document start

**Given** a site with an enabled script set to inject at document start
**When** the webview loads a page
**Then** the script runs before the page's own scripts execute

#### Scenario: Inject at document end

**Given** a site with an enabled script set to inject at document end
**When** the webview finishes loading a page
**Then** the script runs after the DOM is fully loaded

#### Scenario: Disabled scripts are not injected

**Given** a site with a disabled user script
**When** the webview loads a page
**Then** the script is NOT injected

#### Scenario: A script without a header runs on every page

**Given** a site with an enabled script whose source has no `// ==UserScript==` block
**When** the webview loads any page of the site
**Then** the script runs, as it did before headers were read

## ADDED Requirements

### Requirement: US-008 - A script's header is read from its full source

The header SHALL be the first `// ==UserScript==` ... `// ==/UserScript==` block of the script's full source (the fetched library, then the user's code), read each time the script is built for a webview and never stored. Each `// @key value` line inside it is one entry; a key may repeat. A block the app cannot read SHALL count as no header and SHALL NOT stop any webview or script.

#### Scenario: The library's header wins

**Given** a script whose URL fetched a userscript with a header naming `@match https://example.com/a/*`
**And** whose own source has a header naming `@match https://example.com/b/*`
**When** the script is built for the site's webview
**Then** the library's header is the one read

#### Scenario: A header in the user's own code

**Given** a script with no URL whose source starts with a header naming `@name Tidy`
**When** the script is built
**Then** the header names `Tidy`

#### Scenario: An unclosed block is no header

**Given** a source with `// ==UserScript==` and no closing line
**When** the script is built
**Then** it runs as a script without a header
**And** the editor reports that the header is not closed

#### Scenario: Editing the header changes behaviour on the next build

**Given** a script whose header names `@match https://example.com/a/*`
**When** the user edits it to `@match https://example.com/b/*` and saves
**Then** the next webview built for the site runs it on `/b/` pages and not on `/a/` pages

#### Scenario: No header text breaks a build

**Given** any source text, including random bytes and truncated headers
**When** the script is built
**Then** the build completes and every other script of the site is built as before

### Requirement: US-009 - The header decides which pages of an opted-in site run the script

A script whose header names `@match` or `@include` SHALL run only on a page whose URL one of them names, and never on one an `@exclude-match` or `@exclude` names; an exclusion wins. `@match` and `@exclude-match` SHALL follow Chrome's match patterns; `@include` and `@exclude` take a `*` glob over the whole URL or a `/regex/`. The URL SHALL be the document's as the script is about to run, on every path that runs it.

#### Scenario: A matching page runs the script

**Given** an opted-in script with `@match https://*.example.com/watch*`
**When** the site loads `https://www.example.com/watch?v=1`
**Then** the script runs

#### Scenario: Another page of the same site does not

**Given** the same script
**When** the site loads `https://www.example.com/feed`
**Then** the script does not run

#### Scenario: An exclusion wins over a match

**Given** a script with `@match https://example.com/*` and `@exclude-match https://example.com/admin/*`
**When** the site loads `https://example.com/admin/users`
**Then** the script does not run

#### Scenario: A host wildcard does not cross a dot boundary it was not given

**Given** a script with `@match https://*.example.com/*`
**When** the site loads `https://evil-example.com/`
**Then** the script does not run

#### Scenario: A single-page route into a matched path runs the user's code

**Given** a script with `@match https://example.com/watch*` and the site showing `https://example.com/feed`
**When** the page changes its URL to `https://example.com/watch?v=1` without a page load
**Then** the user's own code runs, as the SPA re-run does for any script

#### Scenario: A single-page route out of a matched path does not

**Given** the same script and the site showing `https://example.com/watch?v=1`
**When** the page changes its URL to `https://example.com/feed` without a page load
**Then** the user's code does not run again

#### Scenario: An invalid pattern names no page

**Given** a script whose only `@match` is `https://example.com` (no path)
**When** the site loads any page
**Then** the script does not run
**And** the editor reports the pattern as not valid

#### Scenario: Opt-in still decides the site

**Given** a global script with `@match https://*.youtube.com/*`
**And** a site for `github.com` that opted into it
**When** the site loads any page
**Then** the script does not run

### Requirement: US-010 - `@run-at` sets the injection time

When the header names `@run-at`, the script SHALL run at document start for `document-start` and at document end for `document-end`, `document-idle` and `document-body`. Any other value SHALL leave the stored injection time in force and be reported in the editor. While the header sets it, the editor SHALL show the injection time locked, naming the header as the reason.

#### Scenario: The header moves a script to document start

**Given** a script stored with injection time document end
**And** a header naming `@run-at document-start`
**When** the site loads a page
**Then** the script runs before the page's own scripts

#### Scenario: An unknown value is reported

**Given** a header naming `@run-at context-menu`
**When** the user opens the script in the editor
**Then** the editor lists `context-menu` as not supported
**And** the script runs at its stored injection time

#### Scenario: The editor shows who sets the time

**Given** a script whose header names `@run-at document-start`
**When** the user opens it in the editor
**Then** the injection time reads Document start and cannot be changed there
**And** its reason names the script's header

### Requirement: US-011 - `@name` names a new script

When a script is being created and its name field is empty, the name SHALL be filled from the header's `@name` once the source is pasted or its URL is downloaded. An existing script's name SHALL NOT change when its header does.

#### Scenario: A pasted userscript names itself

**Given** the user adds a new script and leaves the name empty
**When** they paste a source whose header names `@name Hide shorts`
**Then** the name field reads `Hide shorts`

#### Scenario: A name the user typed is kept

**Given** the user adds a new script and types the name `Mine`
**When** they paste a source whose header names `@name Hide shorts`
**Then** the name field still reads `Mine`

### Requirement: US-012 - Keys the app does not provide are reported, not emulated

The editor SHALL list each header key the app does not act on (`@grant` other than `none`, `@require`, `@resource`, `@connect`, `@updateURL`, `@downloadURL`) under a heading saying WebSpace does not provide them. The script SHALL still run, and no `GM_*` or `GM.*` function SHALL be defined in the page.

#### Scenario: A script that asks for GM functions

**Given** a header naming `@grant GM_xmlhttpRequest` and `@require https://code.jquery.com/jquery.min.js`
**When** the user opens the script in the editor
**Then** both are listed as not provided by WebSpace
**And** on a matching page the script runs and `typeof GM_xmlhttpRequest` is `undefined`

#### Scenario: `@grant none` is not reported

**Given** a header naming `@grant none`
**When** the user opens the script in the editor
**Then** nothing is listed as not provided
