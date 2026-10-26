# Design

## Context

A script reaches a page by three paths in `UserScriptService`
(`lib/services/user_script_service.dart`, US-002b):

- the native user script built into `initialUserScripts`, which persists across
  every navigation of the webview;
- the re-injection at load start and load stop, wrapped in the
  once-per-document guard `_guarded`;
- the SPA re-run of the user's own code on `onUpdateVisitedHistory`.

The native path is built once per webview and runs on every document after it,
so only the page knows which URL a run is for. Scripts run in the top frame only
(`ShimFrames.top`). A value reaches a page script only through
`PageJs.withConfig`, which binds JSON to `CONFIG` in an IIFE.

## Goals / Non-Goals

**Goals:**

- One owner for what a header means: a pure Dart parser and compiler. The page
  applies the compiled result and decides nothing itself.
- Gating that cannot be left off a run path: every path builds its text through
  one function that takes the compiled rules.
- Every rule of the matcher held by a table row that a planted mutant of that
  rule fails, with the mutants kept in the test as its proof.

**Non-Goals:**

- `GM_*` / `GM.*` APIs, `@require`, `@resource`, update checks, `@icon`.
  Decided against: most published scripts use them, and a script that needs
  them is reported as such instead.
- An in-app script catalogue (Greasy Fork, OpenUserJS). Decided against: a
  script comes in as source or a URL the user picks.
- Running in frames. `@noframes` is accepted and changes nothing.
- Tampermonkey's `.tld` host suffix and `@match` extensions beyond Chrome's.
- Telling the user in the site's screen that a script names none of the site's
  pages. That needs the site's hosts matched in Dart against every pattern, and
  is left for a follow-up once the compiler exists.

## Decisions

### D1. The header is read on each build, never stored

`parseUserscriptHeader(fullSource)` runs where `UserScriptService` builds a
script. Storing parsed fields beside the source was the alternative; it gives
the header two owners (the text and the fields), which drift on every edit and
every URL re-download, and it changes the persisted format, the backup compat
corpus and the QR codec for nothing. Parsing a header is microseconds.

### D2. Dart compiles patterns; the page only tests them

`compileUserscriptMatch` turns each `@match`, `@exclude-match`, `@include` and
`@exclude` into an anchored regular expression source, or into a
`HeaderProblem.invalidPattern` when it is not valid. Match patterns follow
Chrome's grammar (scheme `*` means http and https; a host `*.` prefix matches
the host and its subdomains on a dot boundary; the path is a glob). An
`@include` glob escapes everything but `*`; a `/.../flags` value is passed
through as the user's own regex.

The page gate (`lib/js/userscript_gate.js`, `PageJs.userscriptGate`) receives
`{include: [...], exclude: [...]}` and returns whether `location.href` is
included and not excluded. A `SyntaxError` from a user regex the JS engine
rejects counts as no match, caught by type.

Alternatives: a matcher written in JS alone, which leaves the editor unable to
report an invalid pattern; or one in each language, two owners held equal by a
shared table, which CLAUDE.md rule 1 calls a bug. With Dart owning the grammar,
the JS side is a loop over `RegExp.test` and has nothing to drift.

### D3. One builder wraps every run path

`UserScriptService` gets one private builder,
`_runnable(script, header:, once:)`, that returns
`{ const ok = <gate>; if (ok && <once guard>) { source } }` (the once guard
omitted for the SPA re-run). `buildInitialUserScripts`, `reinjectOnLoadStart`,
`reinjectOnLoadStop` and `reinjectOnSpaNavigation` call it and nothing else
builds script text. The SPA re-run is gated the same way, so a route into a
matched path runs the user's code and a route out of one does not (US-009).

### D4. Typed results, exhaustive labels

`UserscriptHeader` is a record with required fields: `name`, `include`,
`exclude` (compiled), `runAt` (`UserScriptInjectionTime?`), `notProvided`
(keys), `problems`. `HeaderProblem` is sealed (`unclosed`, `invalidPattern`,
`unknownRunAt`); the editor labels it with an exhaustive `switch`, so a new
problem kind does not compile until the editor says it.

### D5. Editor

The editor parses the text in the source field (and the cached URL source) on
each change, debounced, and shows under the source:

- the pages the script runs on and is excluded from, or "every page of the
  site";
- the injection time, locked with `Lock.because` naming the header when
  `@run-at` sets it;
- what WebSpace does not provide, and the header's problems.

The name prefill (US-011) runs only while the editor is creating a script and
the name field is empty.

### D6. How it is tested

Each layer is tested at its own boundary, and each check is shown to catch a
planted mistake that stays in the test file.

| Layer | Test | Planted mistake it must catch |
|---|---|---|
| Parser | `test/userscript_header_test.dart`: a table of headers to records; the US-008 cases | header taken from the user's code before the library |
| Parser robustness | same file: 10k seeded random and mutated headers never throw and parse the same twice | none (it fails on a throw) |
| Compiler | `test/userscript_match_test.dart`: Chrome's documented match-pattern examples plus Tampermonkey include cases, each row a URL and the expected answer | host `*` crossing dots; scheme `*` matching `file:`; path anchor dropped; glob not escaping `.`; exclusion losing to inclusion |
| Gate | `test/js/userscript_gate.test.js` in jsdom: the gate with sample configs over a URL matrix, and a regex the engine rejects | gate ignoring `exclude` |
| Service | `test/user_script_build_test.dart`: each of the four run paths emits the gate with the header's rules; a script without a header emits an include-all gate | the SPA path built without the gate |
| Editor | `test/user_script_editor_header_test.dart`: summary, lock and prefill (US-010, US-011, US-012) | prefill overwriting a typed name |
| End to end | `integration_test/userscript_match_test.dart`, which the Linux job's loop over `integration_test/*_test.dart` picks up: two paths of a fixture site, a script with `@match` for one, a DOM marker present on that path only | none (it fails if the gate never reaches a real webview) |

A planted mistake is a copy of the function with one fault, kept beside the
table as a list the test runs; each must fail at least one row. Test names cite
US-008 to US-012 so `test/js/spec_verification.test.js` sees them.

## Risks / Trade-offs

- [A user pasted a full userscript before this change, and it ran everywhere;
  after it, the header narrows it] → this is what the header's author asked for;
  the editor shows the pages. The changelog says so.
- [A user regex in `@include` is slow (ReDoS)] → it runs in the page, once per
  run, at the cost of the page that runs it, as the page's own code could.
- [Dart and JS regex engines disagree on a user regex] → the generated
  patterns use a subset both engines read the same; a user regex the page's
  engine rejects counts as no match, which the jsdom test covers.
- [A re-downloaded library changes its header] → read on the next build, so
  the new header applies from the next webview built; nothing to migrate.

## Migration Plan

None. Nothing persisted changes; removing the header lines restores today's
behaviour for a script.
