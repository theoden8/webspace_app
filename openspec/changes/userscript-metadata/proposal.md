# Proposal

## Why

Every published userscript (Greasy Fork, OpenUserJS, a project's GitHub) opens
with a `// ==UserScript==` header naming the pages it is for and when it runs.
User Scripts read none of it today, so a pasted script runs on every page of
the site, including the ones its author excluded, and is set up by hand. Reading
the header makes that catalogue pluggable on all four platforms with no new
engine, and it is the cheapest extension point the app can offer everywhere.

## What Changes

- A script's header, the first `// ==UserScript==` ... `// ==/UserScript==`
  block of its full source (a library fetched from its URL first, then the
  user's own code), is read whenever the script is built for a webview. Nothing
  new is stored: the header text is the one owner of what it says.
- `@match`, `@exclude-match`, `@include` and `@exclude` decide which pages of an
  opted-in site run the script. A script whose header names none of them runs
  on every page of the site, as today. Per-site opt-in still decides the site.
- `@run-at` decides the injection time when present, and the editor shows the
  injection time as set by the header.
- `@name` fills the name of a script being created when the name field is empty.
- Keys the app does not provide (`@grant` other than `none`, `@require`,
  `@resource`, `@connect`, update URLs) are listed in the editor as not
  provided. The script still runs; no `GM_*` function is defined.
- A header the app cannot read is treated as absent and reported in the editor.
  It never stops a webview from being built or another script from running.
- No change to storage, settings backups, QR shares, per-site opt-in or the
  privileged bridge.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `user-scripts`: US-002 (Script Injection) is narrowed by the header; new
  requirements cover reading the header, page matching, `@run-at`, `@name` and
  reporting keys the app does not provide.

## Impact

- New pure Dart parser and match compiler in `lib/services/`
  (`userscript_header.dart`), a new page script `lib/js/userscript_gate.js`
  read through `PageJs`.
- `lib/services/user_script_service.dart`: every path that runs a script (the
  native user script, the re-injection at load start and stop, the SPA re-run)
  goes through the gate.
- `lib/screens/user_scripts.dart`: the editor's header summary, the injection
  time lock and the name prefill; new strings in `lib/l10n/app_en.arb`, then
  the 66 translations in their own commit.
- Tests: Dart parser and compiler tables with planted mutants, a fuzz test,
  jsdom tests of the gate, service tests per run path, an editor widget test and
  a Linux integration test against the fixture server.
- No persisted format changes and no backup compat fixture changes.
