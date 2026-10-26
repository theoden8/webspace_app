# Tasks

## 1. Header parser

- [ ] 1.1 Add `lib/services/userscript_header.dart` with `parseUserscriptHeader(fullSource)` returning the `UserscriptHeader` record and the sealed `HeaderProblem` (design D1, D4); pure Dart, no Flutter import; verify `node test/js/layers.test.js` passes
- [ ] 1.2 Add `test/userscript_header_test.dart`: the table of headers to records and the US-008 scenarios, with test names citing US-008; verify `fvm flutter test test/userscript_header_test.dart` passes
- [ ] 1.3 Add the seeded robustness test (random and mutated headers never throw, two parses agree) in the same file, with a fixed seed it prints on failure; verify it passes
- [ ] 1.4 Add the planted mutant "header taken from the user's code before the library" as a kept list the table must fail; verify the test fails when the mutant list is run against the table and passes on the real parser

## 2. Match compiler

- [ ] 2.1 Add `compileUserscriptMatch` to `userscript_header.dart` (design D2): Chrome match patterns, `@include` globs and `/regex/`, invalid input to `HeaderProblem.invalidPattern`; verify `fvm flutter analyze` is clean
- [ ] 2.2 Add `test/userscript_match_test.dart`: Chrome's documented match-pattern examples and Tampermonkey include cases as URL rows, test names citing US-009; verify it passes
- [ ] 2.3 Keep the five planted mutants from design D6 beside the table; verify each fails at least one row and the test asserts it

## 3. Page gate

- [ ] 3.1 Add `lib/js/userscript_gate.js`, its `PageJs.userscriptGate` value and a sample config in `test/js/helpers/page_js_samples.js`; verify `npm run test:js` passes, including `page_js.test.js` and `page_js_lint.test.js`
- [ ] 3.2 Add `test/js/userscript_gate.test.js` in jsdom: include and exclude over a URL matrix, a regex the engine rejects counts as no match (typed catch), and the planted mutant "gate ignores exclude"; verify `npm run test:js` passes

## 4. Run paths

- [ ] 4.1 Add the single builder `_runnable(script, header:, once:)` to `UserScriptService` and route `buildInitialUserScripts`, `reinjectOnLoadStart`, `reinjectOnLoadStop` and `reinjectOnSpaNavigation` through it (design D3); take the injection time from `header.runAt` when set (US-010); verify `fvm flutter test test/user_script_build_test.dart` passes
- [ ] 4.2 Extend `test/user_script_build_test.dart`: each run path emits the gate with the header's rules, a script without a header emits an include-all gate, `@run-at` moves a script between start and end, and the planted mutant "SPA path built without the gate" fails; test names cite US-002, US-009, US-010; verify it passes
- [ ] 4.3 Assert no `GM_*` or `GM.*` name is defined by any page script the app installs (US-012), as a jsdom test over every `PageJs` value's sample; verify `npm run test:js` passes

## 5. Editor

- [ ] 5.1 Add the header summary, the `@run-at` lock (`Lock.because`) and the `@name` prefill to the editor in `lib/screens/user_scripts.dart` (design D5), with new keys and descriptions in `lib/l10n/app_en.arb`; verify `fvm dart tool/gen_l10n.dart` and `fvm flutter analyze` are clean and `npm run test:js` passes `l10n_no_hardcoded_text` and `settings_hint_placement`
- [ ] 5.2 Add `test/user_script_editor_header_test.dart` (through `pumpLocalized`): the summary lists pages, exclusions and what is not provided; the lock names the header; prefill fills an empty name and keeps a typed one; test names cite US-010, US-011, US-012; verify it passes
- [ ] 5.3 Commit the 66 translated `app_*.arb` files in their own commit on top of 5.1; verify `npm run test:js` passes `l10n_coverage` and `l10n_language`

## 6. End to end and bookkeeping

- [ ] 6.1 Add `integration_test/userscript_match_test.dart`: a fixture-server site with `/a/` and `/b/`, a script with `@match` for `/a/*` that sets a DOM marker, the marker present on `/a/` only; verify it passes locally on Linux (`fvm flutter test integration_test/userscript_match_test.dart -d linux`)
- [ ] 6.2 Remove US-008 to US-012 from `openspec/unverified.tsv` as their tests land; verify `node --test test/js/spec_verification.test.js` passes
- [ ] 6.3 Note the narrowing in the release's fastlane changelog when this ships; verify `scripts/validate_fastlane_metadata.sh` passes
- [ ] 6.4 Run `./scripts/test_all.sh` and `npx openspec validate --no-interactive --all`; verify both exit 0

## Workflow follow-up

- Sync the delta into `openspec/specs/user-scripts/spec.md` and archive the change once merged.
